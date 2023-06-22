import yaml
import os

services = {}
with open("conf/services.yaml") as service_definitions:
	service_yaml = (yaml.load(service_definitions, Loader=yaml.Loader))
	if service_yaml:
		services = service_yaml["services"]

for name, service in services.items():
	os.environ["SERVICE_PATH"] = service["path"]
	os.environ["SERVICE_URL"] = service["url"]
	os.environ["DOLLAR"] = "$"

	service_dir = "/usr/local/openresty/nginx/services"
	os.system(
		"envsubst < %s/service.template > %s/%s.conf" % 
		(service_dir, service_dir, service["path"])
	)