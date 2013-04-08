#!/bin/bash

#  

#  Script to create (to sdt out) SQL statements for
#+ populating the contacts table with our standard
#+ categories and the municipality default email address
#+ (same one for all categories within a municipality).
#
#  Set the file with area_id:s and emails to the
#+ CSV_FILE variable. The file should have the
#+ following syntax:
#
#  Gothham City;666;contact@gotham.se
#
#  Where 666 is the area_id for Gothham. One
#  City;ID;Email entry per line.
#  Only ID and Email is being used, the name
#+ is there for reference and ocular verification.
#
#  The cats variable is an array with the category names.


CSV_FILE=/home/fms/municipalities_ids_email.csv
cats=("Avfall och återvinning" "Cykelställ" "Gatubelysning" "Gång- och cykelbana" "Hållplats" "Igensatt brunn" "Klotter" "Lekplatser" "Nedskräpning" "Offentlig toalett" "Park" "Parkering" "Trafiksignaler" "Träd och buskage" "Vatten och avlopp" "Vinterväghållning" "Vägar" "Vägmärken och skyltar" "Övrigt")

cat $CSV_FILE|while read line
do
 id=`echo $line|cut -d ';' -f2`;
 email=`echo $line|cut -d ';' -f3`;
 #echo "Email: $email id: $id"
 # loop through the array
 for i in $(seq 0 $((${#cats[@]} - 1)))
 do
  echo "INSERT INTO contacts (area_id, category, email, confirmed, deleted, editor, whenedited, note) VALUES ($id, '"${cats[$i]}"', '"$email"', 't', 'f', 'script', now(), '');"
 done
done

#  Next, redirect the output to a file, e.g. categories.sql
#+ and insert them thus:
#  psql databasename databaseuser < categories.sql
#
#  //Rikard Fröberg
