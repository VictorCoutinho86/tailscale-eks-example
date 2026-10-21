# Remoção de serviços de plataforma e RDS para Airflow

## Intento

Reduzir o custo e o footprint do cluster removendo os serviços de observabilidade,
backup, Sealed Secrets e CloudNativePG que não estão ativos, sem remover Airflow,
Spark, Kubecost, Argo CD, Karpenter, AWS Load Balancer Controller ou ExternalDNS.
Substituir o banco PostgreSQL do Airflow por uma instância Amazon RDS mínima,
privada e descartável.

## Objetivos

- Remover do app-of-apps e do Terraform: OpenTelemetry Collector, Alloy, Loki,
  kube-prometheus-stack, CloudNativePG, Velero, Sealed Secrets e `airflow-db`.
- Remover os S3 buckets, Pod Identity, RBAC, namespaces, PDBs, alertas,
  ServiceMonitors e configurações específicas desses serviços.
- Manter os buckets de logs do ALB, eventos do Spark e logs remotos do Airflow,
  pois continuam sendo usados por serviços preservados.
- Criar um RDS PostgreSQL para o metadata database do Airflow, em subnets
  privadas e acessível somente pelos workloads privados do EKS.
- Manter a entrega de serviços pelo Argo CD app-of-apps.
- Não colocar senhas em Git ou no state do Terraform.
- Atualizar, no mesmo ciclo, os serviços mantidos para as versões oficiais mais
  recentes compatíveis com o EKS configurado.

## Matriz de versões verificada

Consulta realizada em 21/10/2026 usando Context7 e os índices/releases oficiais.
Os upgrades abaixo fazem parte da implementação; versões dos serviços removidos
não entram na matriz.

| Serviço | Atual | Alvo | Observação |
|---|---:|---:|---|
| AWS Load Balancer Controller | chart 1.13.0 | chart/app 3.6.1 | revisar CRDs, IAM e values; a linha 3.x depreca APIs Gateway `v1beta1` |
| ExternalDNS | chart 1.19.0 | chart 1.23.0 / app 0.23.0 | manter `policy: upsert-only` |
| Argo CD | chart 8.5.7 | chart 10.10.5 / app v3.5.5 | revisar mudanças de values entre charts 8.x–10.x |
| Karpenter | chart 1.13.0 | chart/app 1.15.0 | revisar upgrade guide e manter APIs `karpenter.sh/v1` |
| Apache Airflow | image 3.3.0; chart 1.22.0 | image 3.3.2; chart 1.22.0 | chart oficial 1.22.0 continua atual; atualizar somente a imagem |
| Spark Operator | chart/app 2.5.1 | chart/app 2.5.2 | atualizar lock e pacote vendorizado |
| Kubecost | chart/app 3.2.1 | chart/app 3.3.1 | atualizar lock e pacote vendorizado |
| EKS VPC CNI addon | v1.22.4-eksbuild.3 | v1.23.2-eksbuild.3 | latest compatível retornado pela API para `cluster_version = 1.37` |
| EKS Pod Identity Agent | `most_recent` | v1.4.0-eksbuild.4 | latest compatível retornado pela API |
| EKS CoreDNS | `most_recent` | v1.14.7-eksbuild.11 | latest/default compatível retornado pela API |
| EKS kube-proxy | `most_recent` | v1.37.0-eksbuild.22 | latest/default compatível retornado pela API para 1.37 |
| EKS EBS CSI Driver | `most_recent` | v1.67.1-eksbuild.1 | latest/default compatível retornado pela API |

As versões foram consultadas em 21/10/2026 com
`aws eks describe-addon-versions --profile victor --region us-east-1
--kubernetes-version 1.37`. A versão upstream do VPC CNI pode ser mais nova
que o addon EKS, portanto o alvo do Terraform deve ser o identificador
`-eksbuild` retornado pela API, não apenas a tag do repositório.

### Impacto nos values

- **AWS Load Balancer Controller:** os values atuais continuam válidos. O root
  Application já injeta `clusterName`, `region`, `vpcId` e mantém a ServiceAccount
  pré-criada. Antes do upgrade, aplicar manualmente os CRDs, pois `helm upgrade`
  não os atualiza automaticamente.
- **ExternalDNS:** os values continuam válidos. `policy: upsert-only`,
  `registry: txt`, `provider.name: aws` e `extraArgs.aws-zone-type: public`
  devem permanecer explícitos.
- **Argo CD:** `server.service.type`, `configs.params.server.insecure` e
  `configs.secret.createSecret` continuam suportados, mas `argocd-secret` deve
  ser criado pelo release Terraform e não pelo chart GitOps. O chart 10.x também
  exige revisar `redisSecretInit`: o bootstrap deve garantir a existência de
  `argocd-redis`; manter `enabled: false` no chart GitOps somente se esse Secret
  já existir.
- **Karpenter:** `values.yaml` vazio continua suficiente; o root Application
  injeta `settings.clusterName` e `settings.interruptionQueue`. Os recursos já
  usam `karpenter.sh/v1` e `karpenter.k8s.aws/v1`, portanto devem ser validados
  contra os CRDs novos, sem migração de API prevista.
- **Airflow:** os nomes dos Secrets, `KubernetesExecutor`, PostgreSQL externo e
  `metadataSecretName` continuam válidos com a imagem 3.3.2. `statsd.enabled`
  e `config.metrics.*` serão removidos/desativados separadamente por não haver
  mais coletor de métricas.
- **Spark Operator:** `webhook.enable: true` continua válido; não há mudança
  necessária nos values.
- **Kubecost:** `networkCosts.enabled`, ServiceAccount pré-criada,
  `cloudCost.serviceAccountName`, `cloudIntegrationJSON` e `extraObjects`
  continuam válidos no chart 3.3.1; renderizar para confirmar o JSON de CUR.
- **EKS addons:** os pins são compatíveis com Kubernetes `1.37`, cobrem ambas as
  arquiteturas (`amd64` e `arm64`) e substituem todos os `most_recent`.

## Não objetivos

- Não remover Airflow, Spark Operator, Kubecost, Argo CD, Karpenter, AWS Load
  Balancer Controller ou ExternalDNS.
- Não alterar a VPC dual-stack, o acesso privado ao EKS, o Tailscale subnet
  router, o ALB interno ou o ACM/Route 53.
- Não migrar dados do CloudNativePG: o usuário confirmou que a configuração não
  está ativa e pode ser descartada.
- Não adicionar observabilidade, backup, alta disponibilidade ou autoscaling ao
  novo banco.

## Decisões

### Serviços removidos

O root Application deixa de gerar as Applications `otel-collector`, `alloy`,
`loki`, `kube-prometheus-stack`, `cloudnative-pg`, `velero`, `sealed-secrets` e
`airflow-db`. As pastas Helm correspondentes deixam de fazer parte da árvore
GitOps.

O chart `base` deixa de criar o namespace `monitoring`, o namespace
`sealed-secrets` e as regras de acesso ao `cnpg-system`/`monitoring`. Também
deixa de renderizar `PrometheusRule`, `ServiceMonitor` e o PDB do Sealed
Secrets. O StatsD do Airflow será desativado, pois não haverá coletor de
métricas.

### Infraestrutura AWS removida

- `velero.tf` será removido integralmente.
- `database.tf` será removido integralmente.
- A parte de Loki e seu Pod Identity serão removidos de `observability.tf`;
  buckets de ALB e Spark permanecem.
- As associações e políticas de Pod Identity de Velero, Loki e CloudNativePG
  serão removidas. A identidade do Airflow para S3/EBS permanece.
- Os parâmetros `cnpgBackupBucket`, `veleroBucket` e `lokiBucket` deixam de ser
  passados pelo bootstrap Terraform e pelos values do root Application.

### RDS do Airflow

Criar `airflow-rds.tf` com:

- `aws_db_subnet_group` usando as três subnets privadas do VPC;
- security group dedicado, permitindo TCP/5432 somente dos CIDRs IPv4/IPv6
  privados do VPC;
- `aws_db_instance` PostgreSQL 17, `db.t4g.micro`, 20 GiB `gp3`, `network_type`
  `DUAL`, `multi_az = false` e `publicly_accessible = false`;
- `storage_encrypted = true` usando a chave gerenciada padrão do RDS, sem criar
  uma chave KMS própria;
- `backup_retention_period = 0`, `delete_automated_backups = true`,
  `skip_final_snapshot = true` e `deletion_protection = false`;
- `monitoring_interval = 0`, `performance_insights_enabled = false` e nenhum
  log exportado para CloudWatch;
- `master_password_wo`/`master_password_wo_version`, recebidos por uma variável
  sensível local, para não persistir a senha no state do Terraform.

O banco terá database e usuário `airflow`. Não haverá RDS Proxy, Multi-AZ,
read replica, backup, snapshot, Enhanced Monitoring ou Performance Insights.

### Segredos sem Sealed Secrets

Não será adicionado External Secrets Operator ou outro serviço pago. A senha do
RDS será fornecida localmente ao Terraform pela nova variável sensível
`airflow_db_password` e o provider usará o atributo write-only `password_wo`.

Um novo script local substituirá `scripts/seal-secrets.sh`. Ele exigirá a senha
do RDS via variável de ambiente, gerará as chaves do Airflow, obterá o endpoint
do RDS via output do Terraform e aplicará diretamente no cluster os Secrets:

- `airflow-fernet-key`;
- `airflow-jwt-secret`;
- `airflow-api-secret-key`;
- `airflow-admin-credentials`;
- `airflow-db-credentials`, contendo `username`, `password` e a connection URI.

Os valores não serão gravados em Git nem em Terraform state. O EKS continua
protegendo Secrets em repouso com a criptografia KMS do cluster. A criação é
intencionalmente operacional, fora do Argo CD, para não reintroduzir outro
controlador nem custo recorrente.

O Secret `argocd-secret` volta a ser criado pelo Helm release de bootstrap do
Argo CD. A Application GitOps do Argo CD não tentará recriá-lo, evitando
conflito de ownership.

### Airflow

O chart do Airflow continua com PostgreSQL embutido desabilitado e mantém
`metadataSecretName: airflow-db-credentials`. O `airflow-db` Application,
Cluster, ScheduledBackup e SealedSecret deixam de existir; a connection URI
passa a apontar para o endpoint RDS criado pelo Terraform.

O Airflow mantém logs remotos e XCom no bucket S3 existente. Logs de pods,
Prometheus, Grafana, Loki e OTLP deixam de ser configurados.

### Documentação e testes

README, contexto arquitetural e diagrama devem refletir somente os serviços
restantes e o RDS sem backup. Testes estáticos devem trocar asserções dos
serviços removidos por asserções de ausência e cobrir os parâmetros destrutivos
do RDS, a rede privada, o uso de `password_wo` e a criação dos Secrets do
Airflow.

Especificações históricas em `docs/superpowers/specs/` não serão reescritas;
elas documentam decisões anteriores. Apenas a documentação operacional atual
será atualizada.

## Riscos aceitos

- A destruição do RDS perde permanentemente os metadados do Airflow, por decisão
  explícita do usuário.
- O RDS será single-AZ e sem backup; indisponibilidade ou perda exige recriação.
- Secrets nativos criados pelo script não são reconciliados pelo Argo CD e
  precisam ser recriados manualmente em um cluster novo.
- `db.t4g.micro`/PostgreSQL 17/DUAL precisam estar disponíveis na região
  configurada; a validação deve ocorrer antes do apply.
- Upgrades de Argo CD, AWS Load Balancer Controller e Karpenter podem alterar
  CRDs, defaults ou comportamento de reconciliação; o plano exige renderização,
  leitura dos changelogs e revisão do `terraform plan` antes do apply.

## Ordem operacional

1. Aplicar a infraestrutura Terraform com o bootstrap Argo CD desativado,
   criando o RDS e sua conectividade.
2. Executar o script de Secrets contra o cluster privado, usando a mesma senha
   informada em `airflow_db_password`.
3. Remover/reconciliar as Applications antigas pelo app-of-apps e aplicar as
   mudanças GitOps.
4. Habilitar o bootstrap Argo CD, se necessário, e validar Airflow, RDS,
   Spark, Kubecost e os serviços restantes.

## Decisões de execução

- O plano deve funcionar tanto para um cluster novo quanto para um cluster já
  criado. Em um cluster existente, não se deve alternar
  `enable_argocd_bootstrap` apenas para fazer esta remoção.
- Buckets de Velero, Loki e CNPG serão destruídos junto com seus recursos
  Terraform. Como são versionados, a execução deve esvaziá-los previamente;
  não haverá retenção fora do Terraform nem migração de dados.
- Na transição, os valores atuais do Airflow serão preservados quando ainda
  existirem. O script não sobrescreve Secrets existentes por padrão; em um
  cluster novo ele gera os valores ausentes. Isso evita invalidar a Fernet key
  e sessões sem necessidade.
- A remoção do Secret selado do Argo CD permite que o Helm bootstrap gere um
  novo Secret. A senha inicial será recuperada do Secret de bootstrap e trocada
  após o sync; não será preservada por Git ou Terraform.
- A connection URI do Airflow para RDS usará `sslmode=require`.
- A rotação da senha do RDS será manual: alterar `airflow_db_password`,
  incrementar `password_wo_version`, aplicar Terraform e executar novamente o
  script de Secrets com a nova senha. Não haverá rotação automática ou
  Secrets Manager.
