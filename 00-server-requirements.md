i have to setup a production server to run application in k8s. give proper plan based on my current server spec. k8s installation and configurations

### Portability note
Everything below is inherently **environment-specific** — it's the literal hardware inventory (hostnames, IPs, CPU/RAM/disk) for this one deployment, not a reusable template. If this cluster is ever replicated elsewhere, this file is rewritten first, and every derived value in `01`-`05` (resource requests, kubelet reservations, replica counts, thread counts) needs re-checking against the new numbers — none of it carries over as-is.

### server spec 

HIMS-PRD-MN-01	10.200.50.129	4 vCPU	12 GB	512 GB	4 vCPU	11.6 GB	501 GB
HIMS-PRD-MN-02	10.200.50.130	4 vCPU	12 GB	512 GB	4 vCPU	11.6 GB	501 GB
HIMS-PRD-WN-01 k8s wn	10.200.50.131	16 vCPU	16 GB	512 GB	16 vCPU	15.5 GB	501 GB only tainted service will run
HIMS-PRD-WN-02 k8s wn	10.200.50.132	8 vCPU	32 GB	512 GB	8 vCPU	31.3 GB	501 GB
HIMS-PRD-WN-03 k8s wn	10.200.50.133	8 vCPU	32 GB	512 GB	8 vCPU	31.3 GB	501 GB
HIMS-PRD-WN-04 k8s wn	10.200.50.134	8 vCPU	32 GB	512 GB	8 vCPU	31.3 GB	501 GB
HIMS-PRD-DB-01 	10.200.50.135	16 vCPU	48 GB	4 TB	16 vCPU	47 GB	4 TB
HIMS-PRD-DB-02 	10.200.50.136	16 vCPU	48 GB	4 TB	16 vCPU	47 GB	4 TB
HIMS-PRD-DB-LB-01 k8s wn 10.200.50.137	8 vCPU	16 GB	512 GB	8 vCPU	15.5 GB	501 GB only tainted service will run here
HIMS-PRD-NFS-01 	10.200.50.138	4 vCPU	16 GB	8 TB	4 vCPU	15.6 GB	8 TB
HIMS-PRD-DB-IG-01 	10.200.50.139	4 vCPU	16 GB	512 GB	4 vCPU	15.6 GB	501 GB
HIMS-PRD-DB-RPT-01 	10.200.50.140	8 vCPU	48 GB	4 TB	8 vCPU	47 GB	4 TB
HIMS-PRD-LOG-01 	10.200.50.141	4 vCPU	16 GB	1 TB	4 vCPU	15.6 GB	1 TB
HIMS-PRD-RPT-01  k8s wn	10.200.50.142	8 vCPU	32 GB	256 GB	8 vCPU	31.2 GB	249 GB   only tainted service will run here


### current planned replicatoin based on service use.

Service Name	Replicas
phx-angular-service	2  | run on any worker node
phx-data-import-service	1 | run on any worker node one time
phx-integration-service	2 | | run on any worker node
phx-node-backend-service	2 | run on any worker node
phx-pharmacy-service	2 | run on any worker node
phx-report-service	1 | run on any worker node 
phx-billing-service	3 | run on any worker node
phx-gateway-service	3 | run on HIMS-PRD-WN-01 if node failed will run on other node
phx-inventory-service	1 | run on any worker node
phx-opd-service	3 | run on any worker node
phx-php-service	3 | run on HIMS-PRD-WN-01 if node failed will run on other node
phx-checkup-service	2 | run on any worker node
phx-ipd-service	2 | run on any worker node
phx-or-service	2 | run on any worker node
phx-queue-service	2 | run on any worker node
phx-database-migration-service	1 | run on any worker node one time
phx-health-promotion-service	2 | run on any worker node
phx-master-service	2 | run on any worker node
phx-patient-service	2 | run on any worker node
phx-referral-service	1 | run on any worker node
phx helical service 1  | run on HIMS-PRD-RPT-01 if node failed dont run
phx db loadbalance servie | tain on HIMS-PRD-DB-LB-01 if node failed will run on other node
phx php nginx service | tain on HIMS-PRD-DB-LB-01 if node failed will run on other node

Ingress nginx pod also planned to run on HIMS-PRD-WN-01

### version in operm servers kubeadms

Component	Technology / Version
Kubernetes Engine	kubeadm v1.31.0, kubelet v1.31.0, kubectl v1.31.0
Container Runtime	containerd
Ingress Controller	NGINX Ingress Controller
Container Network Interface (CNI)	Calico
Load Distribution	Kubernetes Scheduler (Dedicated Gateway Worker Nodes)
Persistent Storage	NFS
TLS / Certificates	
Public CA Certificates (No Wildcard Certificate) 

dont know the ram used by each service since the real conc users 800
some services reach 4 GB ram if used by 20+ users. 