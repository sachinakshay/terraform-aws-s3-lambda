FROM public.ecr.aws/lambda/python:3.9

# Install required packages
RUN pip install boto3 paramiko

# Copy function code
COPY lambda_function.py ${LAMBDA_TASK_ROOT}

# Set the CMD to your handler
CMD [ "lambda_function.handler" ]