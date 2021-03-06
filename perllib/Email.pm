#!/usr/bin/perl
#
# mySociety/Email.pm:
# Email utilities.
#
# Copyright (c) 2006 UK Citizens Online Democracy. All rights reserved.
# WWW: http://www.mysociety.org/

package mySociety::Email::Error;

use Error qw(:try);

@mySociety::Email::Error::ISA = qw(Error::Simple);

package mySociety::Email;

use strict;

use Encode;
use Encode::Byte;   # iso-8859-* etc.
use Error qw(:try);
use MIME::QuotedPrint;
use MIME::Base64;
use POSIX qw();
use Text::Wrap qw();

=item encode_string STRING

Attempt to encode STRING in the least challenging of a variety of possible
encodings. Returns a list giving the IANA name for the selected encoding and a
byte string of the encoded text.

=cut
sub encode_string ($) {
    my $s = shift;

    # Make sure we have an internal Unicode string
    utf8::decode($s);
    foreach my $encoding (qw(
                    us-ascii
                    iso-8859-1
                    iso-8859-15
                    windows-1252
                    utf-8
                )) {
        my $octets;
        eval {
            $octets = encode($encoding, $s, Encode::FB_CROAK);
        };
        return ($encoding, $octets) if ($octets);
    }

    die "Unable to encode STRING in any supported encoding (shouldn't happen, but probably means a blank string has been passed to this function)";
}

my $qpchars = '\x00-\x1f\x7f-\xff?_="(),.:;<>@[\\]';

sub encode_quoted_string($) {
    my $text = shift;
    if ($text =~ /[^A-Za-z0-9!#\$%&'*+\-\/=?^_`{|}~]/) {
        # Contains characters which aren't valid in atoms, so make a
        # quoted-pair instead.
        $text =~ s/(["\\])/\\$1/g;
        $text = qq("$text");
    }
    return $text;
}

=item format_mimewords STRING EMAIL

Return STRING, formatted for inclusion in an email header.
Set EMAIL if being used in a mailbox header, e.g. From or To.

With help from http://mail.nl.linux.org/linux-utf8/2002-01/msg00242.html

=cut
sub format_mimewords ($;$) {
    my ($text, $email) = @_;
    
    my ($charset, $octets) = encode_string($text);
    if ($charset eq 'us-ascii') {
        $text = encode_quoted_string($text) if $email;
        return $text;
    } else {
        my $encoding = length($octets) > 3*(eval "\$octets =~ tr/$qpchars//") ? 'Q' : 'B';
        my $max = $encoding eq 'B'
            ? int((75-7-length($charset))/4)*3-4 # Exclude delimiters, 4:3 always
            : int((75-7-length($charset))/3)-4;  # Exclude delimiters, 3:1 worst case

        my ($last_token, $last_word_encoded, $token) = ('', 0);
        $octets =~ s{(\S+|\s+)}{
            $token = $1;
            if ($token =~ /\s+/) {
                $last_token = $token;
            } else {
                if ($token !~ /[\x00-\x1f\x7f-\xff]/) {
                    $last_word_encoded = 0;
                    $token = encode_quoted_string($token) if $email;
                    $last_token = $token;
                } else {
                    my $tok = $last_token =~ /\s+/ && $last_word_encoded ? $last_token.$token : $token;
                    $tok =~ s{(.{1,$max}[\x80-\xBF]{0,4})}{
                        my $text = $1;
                        if ($encoding eq 'Q') {
                            if ($email) {
                                # Restricted list for phrase replacements, makes sure they're
                                # more restricted than atoms? (RFC 2047, section 5(3) )
                                $text =~ s#([$qpchars\#\$%&'^`{|}~])#sprintf('=%02X', ord($1))#ge;
                            } else {
                                # Encode anything that's not in an RFC 2822 atom. RFC 2047 is
                                # unclear here - it says encoded words should be parsed as atoms,
                                # but also says encoded words can contain any printable ASCII
                                # except "?" and " " (plus "_", "=" for Q-encoding)
                                $text =~ s#([$qpchars])#sprintf('=%02X', ord($1))#ge;
                            }
                            $text =~ s/\s/_/g;
                        } else {
                            $text = encode_base64($text, '');
                        }
                        "=?$charset?$encoding?$text?= ";
                    }seg;
                    $tok = substr($tok, 0, -1);
                    $last_word_encoded = 1;
                    $last_token = $token;
                    $tok;
                }
            }
        }seg;
        local($Text::Wrap::columns) = 75;
        local($Text::Wrap::huge) = 'overflow';
        local($Text::Wrap::unexpand) = 0;
        $octets = Text::Wrap::wrap('', ' ', $octets);
        $octets =~ s/\?= =\?$charset\?$encoding\?//g;
        return $octets;
    }
}

=item format_email_address NAME ADDRESS

Return a suitably MIME-encoded version of "NAME <ADDRESS>" suitable for use in
an email From:/To: header.

=cut
sub format_email_address ($$) {
    my ($name, $addr) = @_;

    # First format name for any non-ASCII characters, if necessary.
    $name = format_mimewords($name, 1);
    return sprintf('%s <%s>', $name, $addr);
}

# do_one_substitution PARAMS NAME
# If NAME is not present in PARAMS, throw an error; otherwise return the value
# of the relevant parameter.
sub do_one_substitution ($$) {
    my ($p, $n) = @_;
    throw mySociety::Email::Error("Substitution parameter '$n' is not present")
        unless (exists($p->{$n}));
    throw mySociety::Email::Error("Substitution parameter '$n' is not defined")
        unless (defined($p->{$n}));
    return $p->{$n};
}

=item do_template_substitution TEMPLATE PARAMETERS

Given the text of a TEMPLATE and a reference to a hash of PARAMETERS, return in
list context the subject and body of the email. This operates on and returns
Unicode strings.

=cut
sub do_template_substitution ($$) {
    my ($body, $params) = @_;
    $body =~ s#<\?=\$values\['([^']+)'\]\?>#do_one_substitution($params, $1)#ges;

    my $subject;
    if ($body =~ m#^Subject: ([^\n]*)\n\n#s) {
        $subject = $1;
        $body =~ s#^Subject: ([^\n]*)\n\n##s;
    }

    $body =~ s/\r\n/\n/gs;
    $body =~ s/^\s+$//mg; # Note this also reduces any gap between paragraphs of >1 blank line to 1

    # Merge paragraphs into their own line.  Two blank lines separate a
    # paragraph. End a line with two spaces to force a linebreak.

    # regex means, "replace any line ending that is neither preceded (?<!\n)
    # nor followed (?!\n) by a blank line with a single space".
    $body =~ s#(?<!\n)(?<!  )\n(?!\n)# #gs;

    # Wrap text to 72-column lines.
    local($Text::Wrap::columns) = 69;
    local($Text::Wrap::huge) = 'overflow';
    local($Text::Wrap::unexpand) = 0;
    #my $wrapped = Text::Wrap::wrap('     ', '     ', $body); #rikard
    my $wrapped = Text::Wrap::wrap('', '', $body); #rikard
    $wrapped =~ s/^\s+$//mg; # Do it again because of wordwrapping indented lines

    return ($subject, $wrapped);
}

=item construct_email SPEC

Construct an email message according to SPEC, which is an associative array
containing elements as given below. Returns an on-the-wire email (though with
"\n" line-endings).

=over 4

=item _body_

Text of the message to send, as a UTF-8 string with "\n" line-endings.

=item _unwrapped_body_

Text of the message to send, as a UTF-8 string with "\n" line-endings. It will
be word-wrapped before sending.

=item _template_, _parameters_

Templated body text and an associative array of template parameters. _template
contains optional substititutions <?=$values['name']?>, each of which is
replaced by the value of the corresponding named value in _parameters_. It is
an error to use a substitution when the corresponding parameter is not present
or undefined. The first line of the template will be interpreted as contents of
the Subject: header of the mail if it begins with the literal string 'Subject:
' followed by a blank line. The templated text will be word-wrapped to produce
lines of appropriate length.

=item To

Contents of the To: header, as a literal UTF-8 string or an array of addresses
or [address, name] pairs.

=item From

Contents of the From: header, as an email address or an [address, name] pair.

=item Cc

Contents of the Cc: header, as for To.

=item Reply-To

Contents of the Reply-To: header, as for To.

=item Subject

Contents of the Subject: header, as a UTF-8 string.

=item I<any other element>

interpreted as the literal value of a header with the same name.

=back

If no Date is given, the current date is used. If no To is given, then the
string "Undisclosed-Recipients: ;" is used. It is an error to fail to give a
body, unwrapped body or a templated body; or From or Subject.

=cut
sub construct_email ($) {
    my $p = shift;

    if (!exists($p->{_body_}) && !exists($p->{_unwrapped_body_})
        && (!exists($p->{_template_}) || !exists($p->{_parameters_}))) {
        throw mySociety::Email::Error("Must specify field '_body_' or '_unwrapped_body_', or both '_template_' and '_parameters_'");
    }

    if (exists($p->{_unwrapped_body_})) {
        throw mySociety::Email::Error("Fields '_body_' and '_unwrapped_body_' both specified") if (exists($p->{_body_}));
        my $t = $p->{_unwrapped_body_};
        $t =~ s/\r\n/\n/gs;
        my $sig;
        $sig = $1 if $t =~ s/(\n-- \n.*)//ms;
        local($Text::Wrap::columns) = 69;
        local($Text::Wrap::huge) = 'overflow';
        local($Text::Wrap::unexpand) = 0;
        $p->{_body_} = Text::Wrap::wrap('     ', '     ', $t);
        $p->{_body_} =~ s/^\s+$//mg;
        if ($sig) {
            $sig = Text::Wrap::wrap('', '', $sig);
            $p->{_body_} .= $sig;
        }
        delete($p->{_unwrapped_body_});
    }

    if (exists($p->{_template_})) {
        throw mySociety::Email::Error("Template parameters '_parameters_' must be an associative array")
            if (ref($p->{_parameters_}) ne 'HASH');
        
        (my $subject, $p->{_body_}) = mySociety::Email::do_template_substitution($p->{_template_}, $p->{_parameters_});
        delete($p->{_template_});
        delete($p->{_parameters_});

        $p->{Subject} = $subject if (defined($subject));
    }

    if (!exists($p->{Subject})) {
        # XXX Try to find out what's causing this very occasionally
        (my $error = $p->{_body_}) =~ s/\n/ | /g;
        $error = "missing field 'Subject' in MESSAGE - $error";
        throw mySociety::Email::Error($error);
    }
    throw mySociety::Email::Error("missing field 'From' in MESSAGE") if (!exists($p->{From}));

    my %hdr;
    $hdr{Subject} = mySociety::Email::format_mimewords($p->{Subject});

    # To: and Cc: are address-lists.
    foreach (qw(To Cc Reply-To)) {
        next unless (exists($p->{$_}));

        if (ref($p->{$_}) eq '') {
            # Interpret as a literal string in UTF-8, so all we need to do is
            # escape it.
            $hdr{$_} = mySociety::Email::format_mimewords($p->{$_});
        } elsif (ref($p->{$_}) eq 'ARRAY') {
            # Array of addresses or [address, name] pairs.
            my @a = ( );
            foreach (@{$p->{$_}}) {
                if (ref($_) eq '') {
                    push(@a, $_);
                } elsif (ref($_) ne 'ARRAY' || @$_ != 2) {
                    throw mySociety::Email::Error("Element of '$_' field should be string or 2-element array");
                } else {
                    push(@a, mySociety::Email::format_email_address($_->[1], $_->[0]));
                }
            }
            $hdr{$_} = join(', ', @a);
        } else {
            throw mySociety::Email::Error("Field '$_' in MESSAGE should be single value or an array");
        }
    }

    foreach (qw(From Sender)) {
        next unless (exists($p->{$_}));

        if (ref($p->{$_}) eq '') {
            $hdr{$_} = $p->{$_}; # XXX check syntax?
        } elsif (ref($p->{$_}) ne 'ARRAY' || @{$p->{$_}} != 2) {
            throw mySociety::Email::Error("'$_' field should be string or 2-element array");
        } else {
            $hdr{$_} = mySociety::Email::format_email_address($p->{$_}->[1], $p->{$_}->[0]);
        }
    }

    # Some defaults
    $hdr{To} ||= 'Undisclosed-recipients: ;';
    $hdr{Date} ||= POSIX::strftime("%a, %d %h %Y %T %z", localtime(time()));

    foreach (keys(%$p)) {
        $hdr{$_} = $p->{$_} if ($_ !~ /^_/ && !exists($hdr{$_}));
    }

    my ($enc, $bodytext) = encode_string($p->{_body_});
    $hdr{'MIME-Version'} = '1.0';
    $hdr{'Content-Type'} = "text/plain; charset=\"$enc\"";

    my $encoded_body;
    if ($enc eq 'us-ascii') {
        $hdr{'Content-Transfer-Encoding'} = '7bit';
        $encoded_body = $bodytext;
    } else {
        $hdr{'Content-Transfer-Encoding'} = 'quoted-printable';
        $encoded_body = encode_qp($bodytext, "\n");
    }

    my $text = '';
    foreach (keys %hdr) {
        # No caller should introduce a header with a linebreak in it, but just
        # in case they do, strip them out.
        my $h = $hdr{$_};
        $_ eq 'Subject' ? $h =~ s/(\r?\n)(?! )/$1 /gs : $h =~ s/\r?\n/ /gs;
        $text .= "$_: $h\n";
    }

    $text .= "\n" . $encoded_body . "\n\n";
    return $text;
}


1;
