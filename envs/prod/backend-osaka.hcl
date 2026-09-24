# terraform init -backend-config=envs/prod/backend-osaka.hcl
# State for the Osaka stack is kept in the Osaka bucket so a Tokyo outage does
# not block DR operations.
bucket       = "REPLACE-ME-tfstate-ops-osaka"
key          = "alertpipe/prod/ap-northeast-3/terraform.tfstate"
region       = "ap-northeast-3"
encrypt      = true
use_lockfile = true
