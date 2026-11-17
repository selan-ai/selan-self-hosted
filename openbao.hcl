# OpenBao for a company with no Vault of its own. Its data is files in the openbao-data volume:
# a single-node integrated store, since OpenBao 2 has no plain `file` backend.
storage "raft" {
  path    = "/openbao/file"
  node_id = "selan"
}

# Plain HTTP, reached only over the `inside` network, which has no route out.
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

api_addr      = "http://openbao:8200"
cluster_addr  = "http://openbao:8201"
disable_mlock = true
ui            = false
