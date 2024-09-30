#!/bin/bash

# Generate service definitions
python3 ../bin/generate_services.py

# Link user tasks
rm -rf /usr/local/openresty/site/lualib/moko/tasks/user
ln -s /home/moko/project/tasks /usr/local/openresty/site/lualib/moko/tasks/user

envsubst < /usr/local/openresty/nginx/conf/nginx.conf.template >/usr/local/openresty/nginx/conf/nginx.conf
/usr/local/openresty/bin/openresty -g "daemon off;"