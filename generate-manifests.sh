#!/usr/bin/env bash

# Short script to generate manifest files for Falco installation
#   First manifest file for setting up a few prerequisites in AWS
#   Second manifest file for defining the Falco application in ArgoCD
# Safer to deploy these separately
# Requires an EKS cluster with ArgoCD + kubectl, aws cli and argocd cli otherwise it will fail
#  Not much checking is done in the script so common sense is a prerequisite also 
# Intended for lab work; a few things should be handled otherwise in a production environment

# Hardcoded as set up elsewhere
export CLUSTER_NAME="nord"
# Also hardcoded
export AWS_REGION="eu-north-1"
# Arbitary shared name string for bucket, log group etc
export SHARED_NAME="falcotest"

# Destination server as defined in ArgoCD
export DESTINATION_ARGOCD="https://kubernetes.default.svc"
# Helm chart version for Falco
export FALCO_CHART_VERSION="1.19.4"

# Get current account ID
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
# Get oidc string for the cluster $CLUSTER_NAME
export OIDC_PROVIDER=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")

# Quit here if $CLUSTER_NAME cluster not found; command above will already have returned an error message
if [ -z $OIDC_PROVIDER ]; then
  exit 0
fi

cat > falco-prerequisites.yaml <<EOF
# Configure AWS for Falco
# Mostly for lab work, to deal with new EKS clusters (OIDC values changes) and different AWS accounts
# Bucket and log stream names are generated using variables in script
# Relies on crossplane so that must be set up already
# Generated using a script so changes here will be lost
---
apiVersion: iam.aws.crossplane.io/v1beta1
kind: Role
metadata:
  name: falco-role
spec:
  deletionPolicy: Delete
  forProvider:
    assumeRolePolicyDocument: |
      {
        "Version": "2012-10-17",
        "Statement": [
          {
            "Effect": "Allow",
            "Principal": {
              "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
              "StringEquals": {
                "${OIDC_PROVIDER}:aud":"sts.amazonaws.com"
              }
            }
          }
        ]
      }
  providerConfigRef:
    name: provider-aws
---
apiVersion: iam.aws.crossplane.io/v1beta1
kind: Policy
metadata:
  name: falco-policy-definition
spec:
  deletionPolicy: Delete
  forProvider:
    name: ${SHARED_NAME}
    document: |
      {
          "Version": "2012-10-17",
          "Statement": [
              {
                  "Sid": "FalcoLogStream",
                  "Effect": "Allow",
                  "Action": [
                      "logs:CreateLogStream",
                      "logs:DescribeLogGroups",
                      "logs:DescribeLogStreams",
                      "logs:CreateLogGroup",
                      "logs:PutLogEvents"
                  ],
                  "Resource": [
                      "arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNT_ID}:log-group:${SHARED_NAME}:*"
                  ]
              },
              {
                  "Sid": "FalcoListBucket",
                  "Effect": "Allow",
                  "Action": [
                      "s3:ListBucket"
                  ],
                  "Resource": [
                      "arn:aws:s3:::${AWS_ACCOUNT_ID}-${SHARED_NAME}"
                  ]
              },
              {
                  "Sid": "FalcoUpdateBucket",
                  "Effect": "Allow",
                  "Action": [
                      "s3:PutObject",
                      "s3:GetObject",
                      "s3:DeleteObject"
                      ],
                  "Resource": "arn:aws:s3:::${AWS_ACCOUNT_ID}-${SHARED_NAME}/*"
              },
              {
                  "Sid": "FalcoSSM",
                  "Effect": "Allow",
                  "Action": [
                      "ssm:PutParameter",
                      "ssm:GetParameter"
                  ],
                  "Resource": "arn:aws:ssm:*:*:parameter/AmazonCloudWatch-*"
              },
              {
                  "Sid": "FalcoOpenSearch",
                  "Effect": "Allow",
                  "Action": "es:*",
                  "Resource": "arn:aws:es:${AWS_REGION}:${AWS_ACCOUNT_ID}:domain/${SHARED_NAME}/*"
              }
          ]
      }
  providerConfigRef:
    name: provider-aws
---
apiVersion: iam.aws.crossplane.io/v1beta1
kind: RolePolicyAttachment
metadata:
  name: rolepolicyattachment-falco
spec:
  deletionPolicy: Delete
  forProvider:
    policyArn: arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${SHARED_NAME}
    roleNameRef:
      name: falco-role
  providerConfigRef:
    name: provider-aws

---
apiVersion: cloudwatchlogs.aws.crossplane.io/v1alpha1
kind: LogGroup
metadata:
  name: falco-loggroup
spec:
  forProvider:
    logGroupName: "${SHARED_NAME}"
    region: ${AWS_REGION}
    retentionInDays: 1
  providerConfigRef:
    name: provider-aws

---
apiVersion: s3.aws.crossplane.io/v1beta1
kind: Bucket
metadata:
  name: ${AWS_ACCOUNT_ID}-${SHARED_NAME}
  namespace: default
spec:
  deletionPolicy: Delete
  forProvider:
    acl: private
    locationConstraint: ${AWS_REGION}
  providerConfigRef:
    name: provider-aws

EOF


echo "Apply the prerequisites manifest file with"
echo "  kubectl apply -f falco-prerequisites.yaml"

cat > falco-argocd-deploy.yaml <<EOF
# Manifest file for Falco application definition on ArgoCD
# Generated using a script so changes here will be lost
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: falco
  namespace: argocd

spec:
  project: default
  # Sync settings; automatic sync disabled for now
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
    # automated:
    #   selfHeal: true
    #   prune: true
  destination:
    server: "${DESTINATION_ARGOCD}"
    namespace: falco
  source:
    repoURL: 'https://falcosecurity.github.io/charts'
    chart: falco
    targetRevision: "${FALCO_CHART_VERSION}"

    # Helm chart values
    helm:
      values: |+
        falco:
          jsonOutput: true
          jsonIncludeOutputProperty: true
          httpOutput:
            enabled: true

        # Create a new rules file and installs it under /etc/falco/rules.d on the falco pod
        # Gets read after the default rules files
        customRules:
          01-rules-poc.yaml: |-
            # Override existing macro rather than appending to it
            # Access to pods by ArgoCD or Crossplane no longer generate events with this patch
            - macro: k8s_containers
              condition: >
                (container.image.repository in (gcr.io/google_containers/hyperkube-amd64,
                 gcr.io/google_containers/kube2sky,
                 docker.io/sysdig/sysdig, docker.io/falcosecurity/falco,
                 sysdig/sysdig, falcosecurity/falco,
                 fluent/fluentd-kubernetes-daemonset, prom/prometheus,
                 ibm_cloud_containers,
                 public.ecr.aws/falcosecurity/falco)
                 or (k8s.ns.name in ( "kube-system", "argocd", "crossplane-system" )))

        # Addon that manages event streaming 
        falcosidekick:
          enabled: true
          fullfqdn: false
  
          # Useful when exploratory testing, but uses resources and is a little wobbly so probably best avoided
          webui:
            enabled: false
            darkmode: false
  
          # Various configuration settings; a few of the more interesting ones copied here
          config:
            extraEnv: []
            debug: true
            ##
            ## a list of escaped comma separated custom fields to add to falco events, syntax is "key:value\,key:value"
            customfields: ""
  
            # All AWS settings copied here; most not updated
            # Access managed using EKS IRSA so no access keys needed here
            aws:
              accesskeyid: ""
              secretaccesskey: ""
              region: "${AWS_REGION}"
              # Annotate service account with role to set up the IRSA function
              # Role needs to be set up with correct oidc provider and policies etc
              rolearn: "arn:aws:iam::${AWS_ACCOUNT_ID}:role/falco-role"
              cloudwatchlogs:
                # Log group needs to be created manually (use crossplane)
                # Example IAM policy configured to use this log group
                loggroup: "${SHARED_NAME}"  
                # Leave empty; Falco creates the logstream 'falcosidekick-logstream' if empty
                # A specified logstream must be created manually, which crossplane can't do, so simpler to leave empty
                logstream: ""
                minimumpriority: "debug"
              lambda:
                functionname: ""
                minimumpriority: ""
              sns:
                topicarn: ""
                rawjson: false
                minimumpriority: ""
              sqs:
                url: ""
                minimumpriority: ""
              s3:
                # Bucket defined in manifest for prerequisites 
                bucket: "${AWS_ACCOUNT_ID}-${SHARED_NAME}"
                # Prefix created automatically
                prefix: "event-log"
                minimumpriority: "debug"
  
            elasticsearch:
              # Streaming to ElasticSearch / OpenSearch
              # OpenSearch endpoint example (was used for proof-of-concept testing)
              # hostport: "https://vpc-falco-test-tno6oebnehg4mgznxwh3d4w23u.eu-north-1.es.amazonaws.com"
              # Disable with an empty value for hostport key
              hostport: ""
              index: "falco"
              type: "event"
              minimumpriority: ""
              mutualtls: false
              checkcert: false
              # UID / password used in lab example for simplicity
              username: "falco"
              password: "not-A-Password"

EOF

echo "And apply the manifest file for deploying onto ArgoCD with"
echo "  kubectl apply -f falco-argocd-deploy.yaml"


