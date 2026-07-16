# /// script
# requires-python = ">=3.14"
# dependencies = ["diagrams>=0.24.0"]
# ///

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import EC2, EKS
from diagrams.aws.network import Endpoint, PublicSubnet, VPC
from diagrams.aws.storage import S3
from diagrams.k8s.compute import Deploy, Pod
from diagrams.k8s.network import Service
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
    user = User("User device\nTailscale tailnet")

    with Cluster("AWS VPC: public subnets across AZs, no NAT"):
        vpc = VPC("VPC")
        s3_endpoint = Endpoint("S3 Gateway\nEndpoint")
        s3 = S3("S3")

        with Cluster("Public subnets"):
            bootstrap = EC2("Bootstrap EC2\nsubnet router + installer")
            default_nodes = EKS("Default node group\n4x t4g.small\nOn-Demand")
            karpenter_nodes = EKS("Default Karpenter nodes\nt2/t3/t4g\nSpot or On-Demand")
            spark_nodes = EKS("Spark NodePool\nr family + NVMe\nSpot or On-Demand")

        eks_api = EKS("EKS private\nAPI endpoint")

        with Cluster("Cluster system"):
            tailscale_operator = Deploy("Tailscale Operator\nTailscale Services")
            argocd = Deploy("Argo CD\nGitOps reconciler")
            karpenter = Deploy("Karpenter\ncontroller")
            storage_class = StorageClass("default gp3\nStorageClass")

        with Cluster("Platform workloads"):
            airflow = Pod("Airflow\nKubernetesExecutor")
            kubecost = Pod("Kubecost")
            spark_operator = Deploy("Spark Operator")

        airflow_service = Service("Airflow\nTailscale Service")
        kubecost_service = Service("Kubecost\nTailscale Service")
        argocd_service = Service("Argo CD\nTailscale Service")

    user >> Edge(label="AWS EKS kubeconfig\nover subnet route") >> bootstrap
    user >> Edge(label="tailnet HTTPS") >> argocd_service >> argocd
    user >> Edge(label="tailnet HTTP") >> airflow_service >> airflow
    user >> Edge(label="tailnet HTTP") >> kubecost_service >> kubecost

    bootstrap >> Edge(label="private endpoint bootstrap") >> eks_api
    bootstrap >> Edge(label="Helm install") >> tailscale_operator
    bootstrap >> Edge(label="Helm install") >> argocd
    bootstrap >> Edge(label="apply root Application") >> argocd

    argocd >> Edge(label="sync") >> karpenter
    argocd >> Edge(label="sync") >> airflow
    argocd >> Edge(label="sync") >> kubecost
    argocd >> Edge(label="sync") >> spark_operator
    argocd >> Edge(label="sync") >> storage_class

    default_nodes >> tailscale_operator
    default_nodes >> argocd
    default_nodes >> karpenter
    karpenter >> Edge(label="provisions") >> karpenter_nodes
    karpenter >> Edge(label="provisions tainted spark nodes") >> spark_nodes
    spark_operator >> Edge(label="runs Spark apps") >> spark_nodes
    storage_class >> Edge(label="PVCs") >> airflow
    storage_class >> Edge(label="PVCs") >> kubecost

    vpc >> s3_endpoint >> s3
