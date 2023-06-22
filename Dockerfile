FROM openresty/openresty:1.21.4.1-0-jammy

# Install python and libraries
RUN apt install -y python3 python3-pip

# Install python libraries
RUN pip install pyyaml

# Install third-party openresty libraries
RUN opm get DevonStrawn/lua-resty-route
RUN /usr/local/openresty/luajit/bin/luarocks install lua-yaml

# Install Moko Gateway library
COPY ./lib /usr/local/openresty/site/lualib/moko

# Copy nginx config
COPY ./conf/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY ./conf/moko.conf /usr/local/openresty/nginx/sites/moko.conf
COPY ./conf/service.template /usr/local/openresty/nginx/services/service.template

RUN mkdir /home/moko
WORKDIR /home/moko

# Copy moko entrypoint and setup files
COPY ./bin bin

# Create user environment
RUN mkdir project
WORKDIR project

# Create user space placehodlders
RUN mkdir conf tasks
RUN touch conf/endpoints.yaml conf/services.yaml

CMD ["/home/moko/bin/moko_entrypoint.sh"]

STOPSIGNAL SIGQUIT