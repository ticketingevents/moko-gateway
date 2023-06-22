#!/bin/bash

# Generate service definitions
python3 ../bin/generate_services.py

# Link user tasks
rm -rf /usr/local/openresty/site/lualib/moko/tasks/user
ln -s /home/moko/project/tasks /usr/local/openresty/site/lualib/moko/tasks/user

/usr/local/openresty/bin/openresty -g "daemon off;"