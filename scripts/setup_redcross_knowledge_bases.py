#!/usr/bin/env python3
"""
Script to set up three knowledge bases for American Red Cross chatbot:
1. Biomedical Services
2. Humanitarian Services  
3. Training Services

This script should be run after the CloudFormation stack is deployed.
It uploads knowledge base files to S3 and creates the knowledge bases.

SageMaker: Use --knowledge-base-data-dir to point to the knowledge_base_data
folder (e.g. after cloning the repo). The SageMaker execution role must have
permissions for: s3, bedrock-agent, s3vectors, ssm.
"""

import argparse
import boto3
import json
import os
import sys
import time
from pathlib import Path
from botocore.exceptions import ClientError

def get_aws_account_info():
    """Get AWS account ID and region"""
    sts = boto3.client('sts')
    account_id = sts.get_caller_identity()['Account']
    session = boto3.Session()
    region = session.region_name
    if region is None:
        region = os.environ.get('AWS_REGION') or os.environ.get('AWS_DEFAULT_REGION') or 'us-west-2'
    return account_id, region

def upload_knowledge_base_files(s3_client, bucket_name, lob_name, file_path):
    """Upload a knowledge base file to S3"""
    s3_key = f"{lob_name}/{os.path.basename(file_path)}"
    try:
        with open(file_path, 'rb') as f:
            s3_client.put_object(
                Bucket=bucket_name,
                Key=s3_key,
                Body=f.read(),
                ContentType='text/plain'
            )
        print(f"✅ Uploaded {s3_key}")
        return True
    except Exception as e:
        print(f"❌ Failed to upload {s3_key}: {str(e)}")
        return False

def create_knowledge_base(bedrock_client, s3vectors_client, account_id, region, 
                         lob_name, execution_role_arn, data_bucket_name):
    """Create a knowledge base for a specific line of business"""
    
    # Create vector bucket and index
    vector_bucket_name = f"{account_id}-{region}-kb-{lob_name}-vector-bucket"
    index_name = f"{account_id}-{region}-kb-{lob_name}-vector-index"
    kb_name = f"{account_id}-{region}-kb-{lob_name}"
    datasource_name = f"{account_id}-{region}-kb-{lob_name}-datasource"
    
    try:
        # Create vector bucket
        print(f"Creating vector bucket: {vector_bucket_name}")
        try:
            s3vectors_client.create_vector_bucket(
                vectorBucketName=vector_bucket_name,
                encryptionConfiguration={'sseType': 'AES256'}
            )
            print(f"✅ Created vector bucket: {vector_bucket_name}")
        except ClientError as e:
            error_code = e.response.get('Error', {}).get('Code', '')
            if error_code == 'ConflictException':
                print(f"ℹ️  Vector bucket already exists: {vector_bucket_name}")
            else:
                print(f"⚠️  Error creating vector bucket: {error_code} - {str(e)}")
                raise
        except Exception as e:
            # Fallback: check error message for conflict indicators
            error_str = str(e).lower()
            if 'conflict' in error_str or 'already exists' in error_str:
                print(f"ℹ️  Vector bucket already exists: {vector_bucket_name}")
            else:
                print(f"⚠️  Unexpected error creating vector bucket: {str(e)}")
                raise
        
        # Create vector index
        print(f"Creating vector index: {index_name}")
        try:
            s3vectors_client.create_index(
                vectorBucketName=vector_bucket_name,
                indexName=index_name,
                dimension=1024,
                distanceMetric='cosine',
                dataType='float32'
            )
            print(f"✅ Created vector index: {index_name}")
        except ClientError as e:
            error_code = e.response.get('Error', {}).get('Code', '')
            if error_code == 'ConflictException':
                print(f"ℹ️  Vector index already exists: {index_name}")
            else:
                print(f"⚠️  Error creating vector index: {error_code} - {str(e)}")
                raise
        except Exception as e:
            # Fallback: check error message for conflict indicators
            error_str = str(e).lower()
            if 'conflict' in error_str or 'already exists' in error_str:
                print(f"ℹ️  Vector index already exists: {index_name}")
            else:
                print(f"⚠️  Unexpected error creating vector index: {str(e)}")
                raise
        
        index_arn = f"arn:aws:s3vectors:{region}:{account_id}:bucket/{vector_bucket_name}/index/{index_name}"
        
        # Create knowledge base
        print(f"Creating knowledge base: {kb_name}")
        try:
            kb_response = bedrock_client.create_knowledge_base(
                name=kb_name,
                roleArn=execution_role_arn,
                knowledgeBaseConfiguration={
                    'type': 'VECTOR',
                    'vectorKnowledgeBaseConfiguration': {
                        'embeddingModelArn': f'arn:aws:bedrock:{region}::foundation-model/amazon.titan-embed-text-v2:0',
                        'embeddingModelConfiguration': {
                            'bedrockEmbeddingModelConfiguration': {
                                'dimensions': 1024,
                                'embeddingDataType': 'FLOAT32'
                            }
                        }
                    }
                },
                storageConfiguration={
                    'type': 'S3_VECTORS',
                    's3VectorsConfiguration': {
                        'indexArn': index_arn
                    }
                }
            )
            kb_id = kb_response['knowledgeBase']['knowledgeBaseId']
            print(f"✅ Created knowledge base: {kb_id}")
        except bedrock_client.exceptions.ConflictException:
            # Knowledge base already exists, get its ID
            print(f"ℹ️  Knowledge base already exists, retrieving ID...")
            kb_list = bedrock_client.list_knowledge_bases()
            for kb in kb_list['knowledgeBaseSummaries']:
                if kb['name'] == kb_name:
                    kb_id = kb['knowledgeBaseId']
                    print(f"✅ Found existing knowledge base: {kb_id}")
                    break
            else:
                raise Exception(f"Could not find knowledge base: {kb_name}")
        
        # Create data source
        print(f"Creating data source: {datasource_name}")
        try:
            ds_response = bedrock_client.create_data_source(
                knowledgeBaseId=kb_id,
                name=datasource_name,
                dataSourceConfiguration={
                    'type': 'S3',
                    's3Configuration': {
                        'bucketArn': f"arn:aws:s3:::{data_bucket_name}",
                        'inclusionPrefixes': [f"{lob_name}/"]
                    }
                },
                vectorIngestionConfiguration={
                    'chunkingConfiguration': {
                        'chunkingStrategy': 'FIXED_SIZE',
                        'fixedSizeChunkingConfiguration': {
                            'maxTokens': 200,
                            'overlapPercentage': 10
                        }
                    }
                }
            )
            ds_id = ds_response['dataSource']['dataSourceId']
            print(f"✅ Created data source: {ds_id}")
        except bedrock_client.exceptions.ConflictException:
            # Data source already exists
            print(f"ℹ️  Data source already exists: {datasource_name}")
            # Get existing data source ID
            ds_list = bedrock_client.list_data_sources(knowledgeBaseId=kb_id)
            for ds in ds_list['dataSourceSummaries']:
                if ds['name'] == datasource_name:
                    ds_id = ds['dataSourceId']
                    print(f"✅ Found existing data source: {ds_id}")
                    break
            else:
                raise Exception(f"Could not find data source: {datasource_name}")
        
        # Store in Parameter Store
        ssm_client = boto3.client('ssm')
        kb_param_name = f"/{account_id}-{region}/kb/{lob_name}/knowledge-base-id"
        ds_param_name = f"/{account_id}-{region}/kb/{lob_name}/data-source-id"
        
        ssm_client.put_parameter(
            Name=kb_param_name,
            Value=kb_id,
            Type='String',
            Description=f'American Red Cross {lob_name.title()} Knowledge Base ID',
            Overwrite=True
        )
        print(f"✅ Stored KB ID in Parameter Store: {kb_param_name}")
        
        ssm_client.put_parameter(
            Name=ds_param_name,
            Value=ds_id,
            Type='String',
            Description=f'American Red Cross {lob_name.title()} Data Source ID',
            Overwrite=True
        )
        print(f"✅ Stored Data Source ID in Parameter Store: {ds_param_name}")
        
        # Trigger ingestion job to sync the data
        print(f"Starting ingestion job for {lob_name} knowledge base...")
        try:
            ingestion_response = bedrock_client.start_ingestion_job(
                knowledgeBaseId=kb_id,
                dataSourceId=ds_id,
                description=f"Initial sync for {lob_name} knowledge base"
            )
            ingestion_job_id = ingestion_response['ingestionJob']['ingestionJobId']
            print(f"✅ Started ingestion job: {ingestion_job_id}")
            print(f"   This may take a few minutes. You can check status in the Bedrock console.")
        except Exception as e:
            print(f"⚠️  Could not start ingestion job automatically: {str(e)}")
            print(f"   You may need to trigger it manually from the Bedrock console or use the sync cell in the notebook.")
        
        return {
            'kb_id': kb_id,
            'ds_id': ds_id,
            'kb_name': kb_name,
            'datasource_name': datasource_name
        }
        
    except Exception as e:
        print(f"❌ Error creating knowledge base for {lob_name}: {str(e)}")
        raise

def main():
    """Main function to set up all three knowledge bases"""
    parser = argparse.ArgumentParser(description='Set up Red Cross knowledge bases (vector DBs) for biomedical, humanitarian, training.')
    parser.add_argument(
        '--knowledge-base-data-dir',
        default=os.environ.get('KNOWLEDGE_BASE_DATA_DIR'),
        help='Path to knowledge_base_data folder. Also set via KNOWLEDGE_BASE_DATA_DIR. Required in SageMaker.'
    )
    args = parser.parse_args()

    # Resolve knowledge_base_data path: arg/env > __file__-relative > cwd (for SageMaker/Jupyter, __file__ may be undefined)
    if args.knowledge_base_data_dir:
        knowledge_base_data_dir = Path(args.knowledge_base_data_dir).resolve()
    else:
        try:
            base = Path(__file__).resolve().parent.parent
        except NameError:
            base = Path.cwd()
        knowledge_base_data_dir = base / 'knowledge_base_data'
    if not knowledge_base_data_dir.is_dir():
        print(f"❌ knowledge_base_data dir not found: {knowledge_base_data_dir}")
        sys.exit(1)

    account_id, region = get_aws_account_info()
    print(f"Setting up knowledge bases for account: {account_id}, region: {region}")
    print(f"Knowledge base data dir: {knowledge_base_data_dir}")
    
    # Get S3 bucket name from Parameter Store or use default (stack-scoped: {StackName}-kb-data-bucket)
    ssm = boto3.client('ssm')
    try:
        bucket_param = ssm.get_parameter(Name=f"/{account_id}-{region}/kb/data-bucket-name")
        data_bucket_name = bucket_param['Parameter']['Value']
    except Exception:
        stack_name = os.environ.get('CFN_STACK_NAME', 'RedCrossStackInfra')
        data_bucket_name = f"{stack_name}-kb-data-bucket"
        print(f"⚠️  Using default bucket name: {data_bucket_name} (set SSM or CFN_STACK_NAME if different)")
    
    # Get execution role ARN (stack-scoped name: {StackName}-kb-bedrock-service-role)
    try:
        role_param = ssm.get_parameter(Name=f"/{account_id}-{region}/kb/bedrock-role-arn")
        execution_role_arn = role_param['Parameter']['Value']
    except Exception:
        stack_name = os.environ.get('CFN_STACK_NAME', 'RedCrossStackInfra')
        execution_role_arn = f"arn:aws:iam::{account_id}:role/{stack_name}-kb-bedrock-service-role"
        print(f"⚠️  Using default role ARN: {execution_role_arn} (set SSM or CFN_STACK_NAME if different)")
    
    # Initialize clients
    s3_client = boto3.client('s3')
    bedrock_client = boto3.client('bedrock-agent')
    s3vectors_client = boto3.client('s3vectors')
    
    lobs = {
        'biomedical': {
            'files': ['biomedical/blood-drive-appointments.txt']
        },
        'humanitarian': {
            'files': ['humanitarian/relief-centers-grants.txt']
        },
        'training': {
            'files': ['training/first-aid-classes-registrations.txt']
        }
    }
    
    results = {}
    
    # Upload files and create knowledge bases for each LOB
    for lob_name, lob_config in lobs.items():
        print(f"\n{'='*60}")
        print(f"Setting up {lob_name.upper()} knowledge base")
        print(f"{'='*60}")
        
        # Upload files
        uploaded_count = 0
        for file_path in lob_config['files']:
            full_path = knowledge_base_data_dir / file_path
            if full_path.exists():
                if upload_knowledge_base_files(s3_client, data_bucket_name, lob_name, full_path):
                    uploaded_count += 1
            else:
                print(f"⚠️  File not found: {full_path}")
        
        if uploaded_count == 0:
            print(f"❌ No files uploaded for {lob_name}, skipping knowledge base creation")
            continue
        
        # Create knowledge base
        try:
            result = create_knowledge_base(
                bedrock_client, s3vectors_client, account_id, region,
                lob_name, execution_role_arn, data_bucket_name
            )
            results[lob_name] = result
            print(f"✅ Successfully set up {lob_name} knowledge base")
        except Exception as e:
            print(f"❌ Failed to set up {lob_name} knowledge base: {str(e)}")
            results[lob_name] = {'error': str(e)}
    
    # Print summary
    print(f"\n{'='*60}")
    print("SETUP SUMMARY")
    print(f"{'='*60}")
    for lob_name, result in results.items():
        if 'error' in result:
            print(f"❌ {lob_name}: FAILED - {result['error']}")
        else:
            print(f"✅ {lob_name}: SUCCESS")
            print(f"   Knowledge Base ID: {result['kb_id']}")
            print(f"   Data Source ID: {result['ds_id']}")
            print(f"   Parameter: /{account_id}-{region}/kb/{lob_name}/knowledge-base-id")
    
    print(f"\n✅ Knowledge base setup complete!")

if __name__ == '__main__':
    main()

