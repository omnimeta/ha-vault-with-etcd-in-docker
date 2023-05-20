storage "etcd" {
  address    = "http://etcd_0:2379,http://etcd_1:2379,http://etcd_1:2379"
	path       = "/vault/"
	ha_enabled = "true"
	sync       = "true"
	username   = "root"
	password   = "root"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
	tls_disable = true
}

cluster_name       = "docker-cluster"
cluster_addr       = "http://vault_0:8201"
api_addr           = "http://vault_0:8200"
disable_clustering = false

default_lease_ttl = "168h"
max_lease_ttl     = "620h"

disable_mlock = true
log_level     = "debug"
ui            = true
