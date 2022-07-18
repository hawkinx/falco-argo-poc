# Falco

### Purpose of this document

- To describe what Falco is, what it is used for and why it is recommended to be used
- To describe the ‘proof of concept’ code for integration with EKS and ArgoCD included with this document, and how this could be adapted for use in different environments
- Some comments on Falco rules and how to include custom rules in a Helm chart deployment managed with ArgoCD

## Falco introduction and capabilities

Described as *the de facto Kubernetes threat detection engine* on the Falco web site.

Falco is an open source runtime security tool that parses Linux system calls and creates alerts according to a set of rules. For managed Kubernetes such as EKS, it runs as a daemonset with a Falco pod on every node instance; for on-premises bare metal Kubernetes you probably would install it directly on the nodes themselves.

The alerts are handled as an event stream, which can be configured for consumption by different services. On AWS events can for example be streamed to CloudWatch, to an S3 bucket, to an OpenSearch/ElasticSearch cluster, to SNS/SQS etc.

A default set of rules is provided; these can be amended and custom rules created.

There are also a number of plugins and a plugin SDK for plugins written in Go: [The Falco Project/Plugins](https://falco.org/docs/plugins/)

The purpose of plugins is stated as being to enable new event sources and new event fields to be added. Plugins are relatively new to Falco so there are few available yet.

This page says it all, including links to information on various components: [The Falco Project/Documentation](https://falco.org/docs/)

There is probably already some sort of process in place for dealing with security alerts etc from existing services and platforms; this could be reused for handling input from Falco also.

### Strategy

Initially the best approach is likely to be to use the default rules along with a minor amendment to prevent Crossplane and ArgcoCD activity creating events, though it might be advisable to review the rules with the help of a security expert to ensure that nothing critical is missing. If necessary, a list of missing rules can be drawn up, categorised according to criticality and additional rules created etc.

Deploying Falco is relatively simple; the main pod that detects anomalous behaviour is deployed as a daemonset so all nodes get a copy, while the pod that streams events is deployed as a replicaset with two replicas as the default value. Deciding on how to consume the event stream and how to deal with events is likely to be more difficult and require more time.

### Falco vs AWS GuardDuty

[AWS GuardDuty](https://aws.amazon.com/guardduty/) ‘intelligent threat detection’ is a paid-for service from AWS which might appear to have the same function for EKS as Falco; however GuardDuty’s scope is AWS infrastructure while Falco’s is applications running on EKS/Kubernetes. So the two are complementary and GuardDuty should perhaps be evaluated for use together with Falco.


## Demonstration/proof-of-concept package for Falco+ArgoCD

Once I had started evaluating Falco, I found that like many of the other tools we are looking at working with documentation was limited and there were few useful examples of how to integrate Falco with all the other bits we are using in our environment. This document is a summary of the various notes and readme files I created while getting things to work, written (hopefully) in a way that is understandable by others.

### Description of package

The goal was to create a code package from my proof of concept work that could be used to recreate the proof of concept in a lab environment or that could used as a framework for building more advanced solutions, including configuration of fan-out of events to other services

**Prerequisites:** EKS cluster with crossplane + AWS provider and ArgoCD. Client host with kubectl and awscli.

All work was done on a Debian Bullseye VM client; the script to create the manifest files is standard bash so should work in any bash environment.

The required manifest files (two) are created by the bash script `generate-manifests.sh`; download it, `chmod +x` it if required, check that the prerequisites are in place and run the script.

The bash script contains a few hardcoded values; I have placed most as variables at the top of the script. Probably not very useful for production, but great for lab work and the manifest files can be used as a base to build more sophisticated solutions on.

The script generates two different manifest files:

- `falco-prerequisites.yaml`
- `falco-argocd-deploy.yaml`

Depending on the configuration, an MFA code may be required

The first manifest file uses crossplane to configure an IAM role for use by the Falco sidekick service account that handles event streaming. The policy attached to the role enables streaming to the defined consuming services. In this example I have an S3 bucket and a CloudWatch log group that are used by the Falco streaming function; these are also defined in this manifest file. The policy also includes permissions for access to the OpenSearch cluster that I set up when I tested that; these permissions are left in for reference as ElasticSearch/OpenSearch is currently the preferred way of consuming events as far as I know. Code that defines the bucket and the log group using crossplane is included and verified, but none for OpenSearch as support for that by crossplane is still a work in progress. OpenSearch clusters are rather expensive compared with CloudWatch or S3 also, so less suitable for lab work.

One comment about the name of the S3 bucket - I've used the name `${AWS_ACCOUNT_ID}-falcotest` to keep it (hopefully) unique, given that S3 bucket names are global. The string `falcotest` is from a variable in the bash script that can be changed.

The second manifest file defines the Falco application in ArgoCD; the target cluster is set to the same cluster as ArgoCD and various helm chart values are set to use the S3 bucket + log group that were defined by the prerequisites manifest file.

One detail with the Falco setting for CloudWatch is that the value for the key `logstream` should be left empty; if left empty Falco will create a log stream with the name `falcosidekick-logstream` and stream the events to it. If a value is given, no log stream is created and events are not streamed unless the log stream is created manually. Manual creation of the log stream is not declarative however so unless there is a good reason for doing so, I would suggest keeping the value blank and leaving the rest to Falco.

As well as the helm chart values, the manifest file defining the ArgoCD application is configured to create the `falco` namespace if that is not already done so. Code related to automatic sync is included, but commented out.


### Testing and event generation

For simple test event generation, a built-in test URL can be called:

- Forward the API access port to localhost  
`kubectl -n falco port-forward svc/falco-falcosidekick 2801`

- Create a test event  
`curl -sI -XPOST http://localhost:2801/test`

This is good enough to verify that events are being handled as expected; they will appear both in the S3 bucket and in the CloudWatch log stream after a few seconds.

For more advanced event generation there is a tool available:
[The Falco Project/Event Sources/Generating sample events](https://falco.org/docs/event-sources/sample-events/)

1. Download the generator  
	`git clone git@github.com:falcosecurity/event-generator.git`
2. Deploy the service account  
	`cd event-generator`  
	`kubectl apply -f deployment/role-rolebinding-serviceaccount.yaml`
3. Run the generator as a one-off job  
	`kubectl apply -f deployment/run-as-job.yaml`

This triggers a number of different rules and is useful for demonstration purposes.


## Rules and extensions of rules

As mentioned previously, local rules can be defined or existing rules extended. Initially at least, given what was found during lab work with Falco, adding exemptions to existing rules is required as normal activity by for example ArgoCD or Kubecost pods creates a lot of events.

### Definition of rules

A Falco rules file is in `yaml` format and contains *Elements* of the types *Rules*, *Macros* and *Lists*. The names of the elements describe what they are; macros can be used by rules and other macros, while lists can be used by rules, macros or lists.

For details see Falco's own documentation: [The Falco Project/Rules](https://falco.org/docs/rules/)

### Defining custom rules and extending existing rules

The structure of the rules is fairly simple and existing rules can be either overwritten or extended using the keyword *append*. Falco's own documentation, along with the [default rules file](https://github.com/falcosecurity/falco/blob/master/rules/falco_rules.yaml), provides enough information.

### Deploying custom rules files

This is where it became a little confusing as information I was able to find seemed to assume that Falco was being installed on the nodes themselves for bare-metal Kubernetes. This appears to be the original way of installing Falco, but this option is not available with managed Kubernetes platforms such as EKS where instead Falco is deployed as a daemonset.

Fortunately there is a simple solution, but first some background.

The default configuration for rules files are the two files plus the directory specified below:

- `/etc/falco/falco_rules.yaml`
- `/etc/falco/falco_rules.local.yaml`
- `/etc/falco/rules.d`

It is possible to change this configuration, but it is not advisable to do so and probably no need to either. The files are read in the order given, with the first one being the supplied default rules that gets replaced during upgrades, the second is for local rules and does not get overwritten. Files in the directory get read in last, presumably in alphabetical order (needs to be verified).

When deploying Falco with a Helm chart, the key `customRules:` can be used to define rules files that get placed in the directory `rules.d` on the pods in the daemonset. I could not find this explicitly stated anywhere, but it seemed logical so I tested and it worked as expected. An example of how to create a custom rules file in this way is included in the manifest for defining the ArgoCD/Falco application; for clarity I have copied it below. It is not for an entire rule, just for a macro, but shows how code can be deployed in a custom rules file. The name of the rules file `01-rules-poc.yaml` is arbitary.

```
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

```

Here I have simply added the namespaces `argod` and `crossplane-system` to the list of permitted namespaces.

Proof that rules files are loaded as expected and without errors can be found in the log files of the falco pods, for example:
```
    Thu Jul 14 12:18:38 2022: Falco version 0.32.0 (driver version 39ae7d40496793cf3d3e7890c9bbdc202263836b)
    Thu Jul 14 12:18:38 2022: Falco initialized with configuration file /etc/falco/falco.yaml
    Thu Jul 14 12:18:38 2022: Loading rules from file /etc/falco/falco_rules.yaml:
    Thu Jul 14 12:18:39 2022: Loading rules from file /etc/falco/falco_rules.local.yaml:
    Thu Jul 14 12:18:39 2022: Loading rules from file /etc/falco/rules.d/01-rules-poc.yaml:
    Thu Jul 14 12:18:39 2022: Starting internal webserver, listening on port 8765
```

## Troubleshooting Falco

As always, checking the logs is the first thing to do when things aren't working as expected.

It's fairly straightforward to check Kubernetes logs with Falco; the only thing that caught me out is that all the sidekick pods need to be checked/followed when debugging event streaming as only one of the pods will stream a given event. In my case it was mostly issues with the IAM roles for service accounts (IRSA) that resulted in the pods not having the access I had intended. With the main Falco pods issues with the configuration or the rule definitions will show up in the logs of all pods; syntax errors in the rules definitions for example will be visible in the rule load sequence shown at the end of the Rule sections above.










