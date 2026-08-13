# /// script
# requires-python = ">=3.14"
# dependencies = ["diagrams>=0.24.0"]
# ///

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import EC2, EKS
from diagrams.aws.network import ALB, Endpoint, PrivateSubnet, VPC
from diagrams.aws.storage import S3
from diagrams.k8s.compute import Deploy, Pod
from diagrams.k8s.network import Ingress
from diagrams.onprem.client import User
from diagrams.onprem.database import PostgreSQL


graph_attr = {
    "fontsize": "18",
    "pad": "0.4",
    "splines": "ortho",
}

node_attr = {
    "fontsize": "12",
}

edge_attr = {
    "fontsize": "10",
}


with Diagram(
    "Tailscale EKS Platform",
    filename="docs/architecture",
    outformat="png",
    show=False,
    direction="TB",
    graph_attr=graph_attr,
    node_attr=node_attr,
    edge_attr=edge_attr,
):
    tailnet_client = User("Tailnet client")
    root_terraform = User("Root Terraform\ninfra only")
    argocd = User("Argo CD\nGitOps")

    with Cluster("AWS public Route 53 hosted zone"):
        route53 = Endpoint("Route 53 zone")
        acm = Endpoint("ACM wildcard cert")

    with Cluster("AWS VPC"):
        vpc = VPC("VPC")
        s3_endpoint = Endpoint("S3 Gateway\nEndpoint")
        s3 = S3("S3")

        with Cluster("Public subnets /24\n3 AZs"):
            subnet_router_asg = EC2("2 subnet-router ASGs\nUbuntu 24.04 spot\nTailscale + NAT64")
            eks_api = EKS("EKS private\nAPI endpoint")

        egress_only_igw = Endpoint("Egress-only IGW\nIPv6 internet egress")
        private_route_tables = PrivateSubnet("Private route tables\nIPv4 default + NAT64")
        nat64_dns64 = Endpoint("NAT64/DNS64\ntayga + Unbound")

        with Cluster("Private subnets /20\n3 AZs"):
            default_nodes = EKS("Default node group\nIPv6 Pods")
            karpenter_nodes = EKS("Karpenter nodes\nNitro instances")
            spark_nodes = EKS("Spark NodePool\nr family + NVMe")

            internal_alb = ALB("Internal dual-stack ALB\nHTTPS host routing\nTLS 1.2+")

            with Cluster("Platform services"):
                aws_lb = Deploy("AWS LBC")
                external_dns = Deploy("ExternalDNS")
                karpenter = Deploy("Karpenter")
                velero = Deploy("Velero\nbackups")
                sealed_secrets = Deploy("Sealed Secrets")
                cnpg = Deploy("CNPG Operator")
                prometheus = Deploy("Prometheus +\nAlertManager")

            with Cluster("Data"):
                airflow_db = PostgreSQL("Airflow DB\nCNPG PostgreSQL 17\n10 GiB")

            with Cluster("Apps (Argo CD)"):
                argocd_app = Deploy("Argo CD")
                airflow = Pod("Airflow\nKubernetesExecutor")
                kubecost = Pod("Kubecost")
                spark_operator = Deploy("Spark Operator")
                loki = Pod("Loki\nlog agg")
                otel = Pod("OTel Collector")

            with Cluster("Ingresses"):
                argocd_ingress = Ingress("argocd.*")
                airflow_ingress = Ingress("airflow.*")
                kubecost_ingress = Ingress("kubecost.*")
                monitoring_ingress = Ingress("monitoring.*")

        s3_velero = S3("Velero\nbackups")
        s3_loki = S3("Loki\nlogs")
        s3_cnpg = S3("CNPG\nbackups")
        s3_spark = S3("Spark\nevents")
        s3_alb = S3("ALB\naccess logs")

    # Tailscale connectivity
    tailnet_client >> Edge(label="subnet route") >> subnet_router_asg
    subnet_router_asg >> Edge(label="private EKS API") >> eks_api
    tailnet_client >> Edge(label="HTTPS over subnet route") >> internal_alb

    # Private subnet routing
    subnet_router_asg >> Edge(label="self-configures\nreplace-route") >> private_route_tables
    private_route_tables >> Edge(label="0.0.0.0/0\nIPv4 NAT") >> subnet_router_asg
    private_route_tables >> Edge(label="64:ff9b::/96\nNAT64") >> nat64_dns64 >> subnet_router_asg
    default_nodes >> Edge(label="IPv6 egress") >> egress_only_igw
    karpenter_nodes >> Edge(label="IPv6 egress") >> egress_only_igw

    # Terraform creates infra
    root_terraform >> Edge(label="creates") >> vpc
    root_terraform >> Edge(label="creates") >> subnet_router_asg
    root_terraform >> Edge(label="creates private cluster") >> eks_api
    root_terraform >> Edge(label="DNS validation") >> acm >> Edge(label="cert ARN") >> internal_alb
    root_terraform >> Edge(label="bootstraps") >> argocd_app

    # S3 buckets
    root_terraform >> s3_velero
    root_terraform >> s3_loki
    root_terraform >> s3_cnpg
    root_terraform >> s3_spark
    root_terraform >> s3_alb

    # Argo CD manages everything else
    argocd >> Edge(label="reconciles via\napp-of-apps") >> aws_lb
    argocd >> Edge(label="reconciles") >> external_dns
    argocd >> Edge(label="reconciles") >> karpenter
    argocd >> Edge(label="reconciles") >> velero
    argocd >> Edge(label="reconciles") >> sealed_secrets
    argocd >> Edge(label="reconciles") >> cnpg
    argocd >> Edge(label="reconciles") >> prometheus
    argocd >> Edge(label="reconciles") >> airflow
    argocd >> Edge(label="reconciles") >> kubecost
    argocd >> Edge(label="reconciles") >> spark_operator
    argocd >> Edge(label="reconciles") >> loki
    argocd >> Edge(label="reconciles") >> otel

    # DNS
    external_dns >> Edge(label="upserts DNS/TXT") >> route53

    # ALB
    aws_lb >> Edge(label="reconciles") >> internal_alb
    internal_alb >> argocd_ingress >> argocd_app
    internal_alb >> airflow_ingress >> airflow
    internal_alb >> kubecost_ingress >> kubecost
    internal_alb >> monitoring_ingress >> prometheus

    # Node placement
    default_nodes >> aws_lb
    default_nodes >> external_dns
    default_nodes >> argocd_app
    default_nodes >> karpenter
    karpenter >> Edge(label="provisions") >> karpenter_nodes
    karpenter >> Edge(label="provisions") >> spark_nodes

    # Data dependencies
    cnpg >> Edge(label="provisions") >> airflow_db
    airflow >> Edge(label="metadata") >> airflow_db
    velero >> Edge(label="backups") >> s3_velero
    loki >> Edge(label="chunks") >> s3_loki
    otel >> Edge(label="OTLP logs") >> loki
    spark_operator >> Edge(label="event logs") >> s3_spark

    # VPC endpoint
    vpc >> s3_endpoint >> s3
