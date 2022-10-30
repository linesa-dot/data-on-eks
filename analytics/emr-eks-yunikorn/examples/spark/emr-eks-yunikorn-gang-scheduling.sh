#!/bin/bash

if [ $# -ne 3 ];
then
  echo "$0: Missing arguments EMR_VIRTUAL_CLUSTER_NAME, S3_BUCKET_NAME and EMR_JOB_EXECUTION_ROLE_ARN"
  echo "USAGE: ./emr-eks-yunikorn-team-a.sh '<EMR_VIRTUAL_CLUSTER_NAME>' '<s3://ENTER_BUCKET_NAME>' '<EMR_JOB_EXECUTION_ROLE_ARN>'"
  exit 1
else
  echo "We got some argument(s)"
  echo "==========================="
  echo "Number of arguments.: $#"
  echo "List of arguments...: $@"
  echo "Arg #1..............: $1"
  echo "Arg #2..............: $2"
  echo "Arg #3..............: $3"
  echo "==========================="
fi

#--------------------------------------------
# INPUT VARIABLES
#--------------------------------------------
EMR_VIRTUAL_CLUSTER_NAME=$1     # Terraform output variable is `emrcontainers_virtual_cluster_id`
S3_BUCKET=$2                    # This script requires s3 bucket as input parameter e.g., s3://<bucket-name>
EMR_JOB_EXECUTION_ROLE_ARN=$3   # Terraform output variable is emr_on_eks_role_arn

#--------------------------------------------
# DERIVED VARIABLES
#--------------------------------------------
EMR_VIRTUAL_CLUSTER_ID=$(aws emr-containers list-virtual-clusters --query "virtualClusters[?name == '$EMR_VIRTUAL_CLUSTER_NAME' && state == 'RUNNING'].id" --output text)

#--------------------------------------------
# DEFAULT VARIABLES CAN BE MODIFIED
#--------------------------------------------
JOB_NAME='taxidata'
EMR_EKS_RELEASE_LABEL="emr-6.7.0-latest" # Spark 3.2.1
SPARK_JOB_S3_PATH="${S3_BUCKET}/emr_virtual_cluster_name=${EMR_VIRTUAL_CLUSTER_NAME}/job_name=${JOB_NAME}"

#--------------------------------------------
# CLOUDWATCH LOG GROUP NAME
#--------------------------------------------
CW_LOG_GROUP="/emr-on-eks-logs/${EMR_VIRTUAL_CLUSTER_NAME}" # Create CW Log group if not exist

#--------------------------------------------
# Copy PySpark script and Pod templates to S3 bucket
#--------------------------------------------
aws s3 sync ./spark-scripts/pod-templates "${SPARK_JOB_S3_PATH}/pod-templates"
aws s3 sync ./spark-scripts/scripts "${SPARK_JOB_S3_PATH}/scripts"

#--------------------------------------------
# Execute Spark job
#--------------------------------------------

if [[ $EMR_VIRTUAL_CLUSTER_ID != "" ]]; then
  echo "Found Cluster $EMR_VIRTUAL_CLUSTER_NAME; Executing the Spark job now..."
  aws emr-containers start-job-run \
    --virtual-cluster-id $EMR_VIRTUAL_CLUSTER_ID \
    --name $JOB_NAME \
    --execution-role-arn $EMR_JOB_EXECUTION_ROLE_ARN \
    --release-label $EMR_EKS_RELEASE_LABEL \
    --job-driver '{
      "sparkSubmitJobDriver": {
        "entryPoint": "'"$SPARK_JOB_S3_PATH"'/scripts/spark-catalog-sales.py",
        "entryPointArguments": ["s3://dev-aws-raw-zone/TPCDS-TEST-1T/catalog_sales/",
          "s3://dev-aws-raw-zone/TPCDS-EMR-EKS-OUTPUT/catalog_sales/"
        ],
        "sparkSubmitParameters": "--conf spark.executor.instances=2"
      }
   }' \
    --configuration-overrides '{
      "applicationConfiguration": [
          {
            "classification": "spark-defaults",
            "properties": {
              "spark.driver.cores":"1",
              "spark.executor.cores":"1",
              "spark.driver.memory": "10g",
              "spark.executor.memory": "10g",
              "spark.kubernetes.driver.podTemplateFile":"'"$SPARK_JOB_S3_PATH"'/pod-templates/spark-driver-team-a.yaml",
              "spark.kubernetes.executor.podTemplateFile":"'"$SPARK_JOB_S3_PATH"'/pod-templates/spark-executor-team-a.yaml",
              "spark.local.dir" : "/emrdata",

              "spark.kubernetes.executor.podNamePrefix":"'"$JOB_NAME"'",
              "spark.ui.prometheus.enabled":"true",
              "spark.executor.processTreeMetrics.enabled":"true",
              "spark.kubernetes.driver.annotation.prometheus.io/scrape":"true",
              "spark.kubernetes.driver.annotation.prometheus.io/path":"/metrics/executors/prometheus/",
              "spark.kubernetes.driver.annotation.prometheus.io/port":"4040",
              "spark.kubernetes.driver.service.annotation.prometheus.io/scrape":"true",
              "spark.kubernetes.driver.service.annotation.prometheus.io/path":"/metrics/driver/prometheus/",
              "spark.kubernetes.driver.service.annotation.prometheus.io/port":"4040",
              "spark.metrics.conf.*.sink.prometheusServlet.class":"org.apache.spark.metrics.sink.PrometheusServlet",
              "spark.metrics.conf.*.sink.prometheusServlet.path":"/metrics/driver/prometheus/",
              "spark.metrics.conf.master.sink.prometheusServlet.path":"/metrics/master/prometheus/",
              "spark.metrics.conf.applications.sink.prometheusServlet.path":"/metrics/applications/prometheus/"
            }
          }
        ],
      "monitoringConfiguration": {
        "persistentAppUI":"ENABLED",
        "cloudWatchMonitoringConfiguration": {
          "logGroupName":"'"$CW_LOG_GROUP"'",
          "logStreamNamePrefix":"'"$JOB_NAME"'"
        }
      }
    }'
else
  echo "Cluster is not in running state $EMR_VIRTUAL_CLUSTER_NAME"
fi
