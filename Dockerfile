FROM openresty/openresty:1.27.1.2-4-jammy

# Set default service resolver
ENV SERVICE_DNS=127.0.0.11

# Install python and libraries
RUN apt update -y && apt install -y python3 python3-pip git

# Install python libraries
RUN pip install pyyaml

# Install third-party openresty libraries
RUN opm get DevonStrawn/lua-resty-route
RUN luarocks install lua-resty-rabbitmqstomp
RUN luarocks install lua-yaml
RUN luarocks install luasocket

# Install Moko Gateway library
COPY ./lib /usr/local/openresty/site/lualib/moko

# Copy nginx config
COPY ./conf/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf.template
COPY ./conf/moko.conf /usr/local/openresty/nginx/sites/moko.conf
COPY ./conf/service.*.template /usr/local/openresty/nginx/services/

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

# Define Healthcheck
HEALTHCHECK --interval=5s --timeout=5s --retries=6 \
  CMD ps auxf | grep "[o]penresty -g daemon off" | wc -l

ENTRYPOINT ["/home/moko/bin/moko_entrypoint.sh"]

STOPSIGNAL SIGQUIT