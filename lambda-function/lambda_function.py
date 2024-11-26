import boto3
import paramiko
import os
from io import StringIO
import time

def handler(event, context):
    # Get environment variables
    bucket_name = os.environ['S3_BUCKET']
    instance_id = os.environ['EC2_INSTANCE_ID']
    
    try:
        # Wait for EC2 instance to be fully running (important!)
        ec2 = boto3.client('ec2')
        waiter = ec2.get_waiter('instance_running')
        waiter.wait(InstanceIds=[instance_id])
        
        # Get instance details
        response = ec2.describe_instances(InstanceIds=[instance_id])
        public_ip = response['Reservations'][0]['Instances'][0]['PublicIpAddress']
        
        # Get the .pem file from S3
        s3 = boto3.client('s3')
        response = s3.get_object(Bucket=bucket_name, Key='ec2-key-pair.pem')
        pem_content = response['Body'].read().decode('utf-8')
        
        # Wait a bit for SSH to be ready
        time.sleep(30)
        
        # Setup SSH client
        key = paramiko.RSAKey.from_private_key(StringIO(pem_content))
        ssh = paramiko.SSHClient()
        ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        
        # Try to connect multiple times (EC2 might need time to be ready)
        max_retries = 3
        for i in range(max_retries):
            try:
                ssh.connect(
                    hostname=public_ip,
                    username='ec2-user',
                    pkey=key,
                    timeout=30
                )
                break
            except Exception as e:
                if i == max_retries - 1:
                    raise e
                time.sleep(30)
        
        # Copy the .pem file to EC2
        sftp = ssh.open_sftp()
        with sftp.file('/home/ec2-user/ec2-key-pair.pem', 'w') as f:
            f.write(pem_content)
        
        # Set correct permissions on the .pem file
        ssh.exec_command('chmod 400 /home/ec2-user/ec2-key-pair.pem')
        
        ssh.close()
        
        return {
            'statusCode': 200,
            'body': f'Successfully copied .pem file to EC2 instance {instance_id}'
        }
    
    except Exception as e:
        return {
            'statusCode': 500,
            'body': f'Error: {str(e)}'
        }