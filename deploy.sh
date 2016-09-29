#! /usr/bin/env sh
rsync -avh output/* smalldrop:/var/www/html/ --delete
