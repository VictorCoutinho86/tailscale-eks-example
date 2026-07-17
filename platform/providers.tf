data "terraform_remote_state" "infra" {
  backend = "local"

  config = {
    path = "${path.module}/../terraform.tfstate"
  }
}

provider "aws" {
  region  = data.terraform_remote_state.infra.outputs.aws_region
  profile = var.aws_profile
}

provider "kubernetes" {
  host                   = data.terraform_remote_state.infra.outputs.cluster_endpoint
  cluster_ca_certificate = base64decode(data.terraform_remote_state.infra.outputs.cluster_ca_certificate)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--region",
      data.terraform_remote_state.infra.outputs.aws_region,
      "--cluster-name",
      data.terraform_remote_state.infra.outputs.cluster_name,
      "--profile",
      var.aws_profile,
    ]
  }
}

provider "helm" {
  kubernetes = {
    host                   = data.terraform_remote_state.infra.outputs.cluster_endpoint
    cluster_ca_certificate = base64decode(data.terraform_remote_state.infra.outputs.cluster_ca_certificate)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks",
        "get-token",
        "--region",
        data.terraform_remote_state.infra.outputs.aws_region,
        "--cluster-name",
        data.terraform_remote_state.infra.outputs.cluster_name,
        "--profile",
        var.aws_profile,
      ]
    }
  }
}
