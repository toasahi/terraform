# terraform init -backend-config=envs/prod/backend-tokyo.hcl
bucket       = "REPLACE-ME-tfstate-ops"
key          = "alertpipe/prod/ap-northeast-1/terraform.tfstate"
region       = "ap-northeast-1"
encrypt      = true
use_lockfile = true
