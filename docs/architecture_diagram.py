# /// script
# requires-python = ">=3.14"
# dependencies = ["diagrams>=0.24.0"]
# ///

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import EC2, EKS
from diagrams.aws.network import Endpoint, PublicSubnet, VPC
from diagrams.aws.storage import S3
from diagrams.k8s.compute import Deploy, Pod
from diagrams.k8s.network import Ingress, Service
from diagrams.k8s.storage import StorageClass
from diagrams.onprem.client import User


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
    tailnet_client = User("Tailnet client\nTailscale device")
    root_terraform = User("Root Terraform\nVPC + EKS + ACM")
    platform_terraform = User("Platform Terraform\nhelm_release")

    with Cluster("AWS public Route 53 hosted zone"):
        route53 = Endpoint("Route 53 zone")
        acm = Endpoint("ACM wildcard cert\n*.example.com")

    with Cluster("AWS VPC: public subnets across AZs, no NAT"):
        vpc = VPC("VPC")
        s3_endpoint = Endpoint("S3 Gateway\nEndpoint")
        s3 = S3("S3")

        with Cluster("Public subnets"):
            subnet_router = EC2("Subnet router EC2\nTailscale routes VPC CIDR")
            default_nodes = EKS("Default node group\nt4g.small Spot")
            karpenter_nodes = EKS("Default Karpenter nodes\nt2/t3/t4g")
            spark_nodes = EKS("Spark NodePool\nr family + NVMe")
            internal_alb = PublicSubnet("Internal ALB\nHTTPS host routing")

        eks_api = EKS("EKS private\nAPI endpoint")

        with Cluster("Cluster system"):
            aws_lb_controller = Deploy("AWS Load Balancer\nController")
            external_dns = Deploy("ExternalDNS")
            karpenter = Deploy("Karpenter\ncontroller")
            storage_class = StorageClass("default gp3\nStorageClass")

        with Cluster("Platform Helm releases"):
            argocd = Deploy("Argo CD")
            airflow = Pod("Airflow\nKubernetesExecutor")
            kubecost = Pod("Kubecost")
            spark_operator = Deploy("Spark Operator")

        with Cluster("Namespace-local Ingresses"):
            argocd_ingress = Ingress("argocd.example.com")
            airflow_ingress = Ingress("airflow.example.com")
            kubecost_ingress = Ingress("kubecost.example.com")

        argocd_service = Service("argocd-server:80")
        airflow_service = Service("airflow-api-server:8080")
        kubecost_service = Service("kubecost-frontend:9090")

    tailnet_client >> Edge(label="subnet route") >> subnet_router
    subnet_router >> Edge(label="private EKS API") >> eks_api
    tailnet_client >> Edge(label="HTTPS over subnet route") >> internal_alb

    root_terraform >> Edge(label="creates") >> vpc
    root_terraform >> Edge(label="creates") >> subnet_router
    root_terraform >> Edge(label="creates private cluster") >> eks_api
    root_terraform >> Edge(label="DNS validation") >> acm >> Edge(label="cert ARN") >> internal_alb

    platform_terraform >> Edge(label="aws eks get-token") >> eks_api
    platform_terraform >> Edge(label="installs Helm releases") >> aws_lb_controller
    platform_terraform >> Edge(label="installs Helm releases") >> external_dns
    platform_terraform >> Edge(label="installs Helm releases") >> argocd
    platform_terraform >> Edge(label="installs Helm releases") >> airflow
    platform_terraform >> Edge(label="installs Helm releases") >> kubecost
    platform_terraform >> Edge(label="installs Helm releases") >> spark_operator
    platform_terraform >> Edge(label="installs Helm releases") >> karpenter
    platform_terraform >> Edge(label="creates") >> storage_class

    external_dns >> Edge(label="upserts A/TXT records") >> route53
    aws_lb_controller >> Edge(label="reconciles") >> internal_alb

    argocd_ingress >> internal_alb
    airflow_ingress >> internal_alb
    kubecost_ingress >> internal_alb

    internal_alb >> argocd_ingress >> argocd_service >> argocd
    internal_alb >> airflow_ingress >> airflow_service >> airflow
    internal_alb >> kubecost_ingress >> kubecost_service >> kubecost

    default_nodes >> aws_lb_controller
    default_nodes >> external_dns
    default_nodes >> argocd
    default_nodes >> karpenter
    karpenter >> Edge(label="provisions") >> karpenter_nodes
    karpenter >> Edge(label="provisions tainted nodes") >> spark_nodes
    spark_operator >> Edge(label="runs Spark apps") >> spark_nodes
    storage_class >> Edge(label="PVCs") >> airflow
    storage_class >> Edge(label="PVCs") >> kubecost

    vpc >> s3_endpoint >> s3
