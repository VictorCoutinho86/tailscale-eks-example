terraform {
  backend "s3" {
    bucket       = "tailscale-eks-example"
    key          = "terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}
