# Open Catalog with Polaris

This guide demonstrates how to integrate [Apache Polaris (Incubating)](https://github.com/apache/polaris) CLI with [Snowflake Open Catalog](https://other-docs.snowflake.com/en/opencatalog/overview), Snowflake's managed implementation of Apache Polaris. 

Apache Polaris is an open-source catalog for Apache Iceberg that provides multi-engine interoperability, while Snowflake Open Catalog offers a fully managed version that simplifies deployment and operations. By using the Polaris CLI with Open Catalog, you can programmatically manage catalogs, principals, and access controls in your data lakehouse architecture.

This tutorial walks through setting up the complete integration, including AWS IAM configuration, catalog creation, and user management.

## Requirements
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- [Snowflake CLI](https://docs.snowflake.com/en/user-guide/snowcli-install)
- [HTTPie](https://httpie.io/docs/cli/installation)
- [jq](https://stedolan.github.io/jq/download/)
- [GitHub CLI](https://cli.github.com/)

## Open Catalog Account

This tutorial needs a Open Catalog account with user who has the role `POLARIS_ACCOUNT_ADMIN` to create catalogs and manage principals.

Ensure you have completed setting up Snowflake CLI and Open Catalog to auth with Key Pair. If not done, please follow the steps in the [Open Catalog KeyPair](https://other-docs.snowflake.com/en/LIMITEDACCESS/opencatalog/key-pair-auth#before-you-begin).


## Install Polaris CLI

```bash
gh repo clone https://github.com/apache/polaris
```

Run the following commands to build and run Polaris CLI in current directory:

```bash
./polaris --help
```

## Environment Variables

Create a `.env` file in the current directory with the following content:

```bash
AWS_ACCESS_KEY_ID='your-access-key-id'
AWS_SECRET_ACCESS_KEY='your-secret-access-key'
AWS_SESSION_TOKEN='your-session-token' # Optional, if using temporary credentials
AWS_REGION=us-west-2
WORK_DIR="${PWD}/work"
PATH_TO_POLARIS_CLI="$PWD/polaris:$PATH"
OC_API_URL="https://your-account.snowflakecomputing.com"
SNOWFLAKE_DEFAULT_CONNECTION_NAME="opencatalog-key"
SNOWFLAKE_ACCOUNT_ID="your-account-id"
PRIVATE_KEY_PASSPHRASE='your-private-key-passphrase'
OC_STORAGE_BUCKET_NAME="${USER}-devrel-oc-demo-polardb"
OC_STORAGE_AWS_ROLE_NAME="${USER}-oc-s3-role"
OC_STORAGE_AWS_ROLE_POLICY_NAME="${USER}-oc-s3-role-policy"
OC_CATALOG_NAME="polardb"
OC_ADMIN_USER_NAME="super_user"
```


Create the `.work` directory with right permissions:

```bash
mkdir -p "${WORK_DIR}"
chmod 700 -R "${WORK_DIR}"
```

Load the environment variables:
```bash
source .env
```

> [!TIP]
> Using [direnv](https://direnv.net/) can help manage environment variables automatically when you enter the directory.
> Be sure to hook direnv into your shell by adding the following line to your shell configuration file (e.g., `.bashrc`, `.zshrc`) using the  [guide](https://direnv.net/docs/hook.html).

## Get the Access Token

To authenticate with Open Catalog, you need to generate an access token using the Snowflake CLI. This token will be used in subsequent API calls.

To generate the access token, you can use the following command. This command generates a JWT token and then uses it to request an access token from the Open Catalog API.

```bash
export JWT_TOKEN=$(snow connection generate-jwt)
```

Then, use the generated JWT token to get the access token using the Open Catalog API:

```bash
export ACCESS_TOKEN=$(http --form POST "${OC_API_URL}/polaris/api/catalog/v1/oauth/tokens" \
     Accept:application/json \
     scope="session:role:POLARIS_ACCOUNT_ADMIN" \
     grant_type="client_credentials" \
     client_secret="$JWT_TOKEN" | jq -r ".access_token")
```

> [!IMPORTANT]
> Whenever you get Unauthorized error, you need to regenerate the JWT token and access token.

## Catalog

```bash
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query 'Account' --output text)"
export OC_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${OC_STORAGE_AWS_ROLE_NAME}"
```

### List Catalogs

```bash
polaris \
  --base-url="${OC_API_URL}/polaris" \
  --access-token="${ACCESS_TOKEN}" \
  catalogs list 
```

## Create catalog

```bash
polaris \
  --base-url="${OC_API_URL}/polaris" \
  --access-token="${ACCESS_TOKEN}" \
  catalogs create "${OC_CATALOG_NAME:-polardb}" \
  --type="INTERNAL" \
  --storage-type="S3" \
  --role-arn="${OC_ROLE_ARN}" \
  --external-id="${AWS_EXTERNAL_ID}" \
  --region="${AWS_REGION:-us-west-2}" \
  --default-base-location="s3://${OC_STORAGE_BUCKET_NAME}"
```

Get Catalog Information for use in the next steps:

```bash
polaris \
  --base-url="${OC_API_URL}/polaris" \
    --access-token="${ACCESS_TOKEN}" \
    catalogs list | jq --arg catalog_name "${OC_CATALOG_NAME:-polardb}" '. | select(.name==$catalog_name)' > "${WORK_DIR}/catalog-info.json"
```

Verify catalog information:

```bash
jq . "${WORK_DIR}/catalog-info.json"
```

## Create Related AWS Resources

Create the necessary AWS resources to support the Open Catalog integration, including an S3 bucket for storage and an IAM role with appropriate policies. 

> [!NOTE]
> This step is optional if you already have an S3 bucket and IAM role set up for Open Catalog.

### S3 bucket
Create an S3 bucket to store the catalog data. You can use any S3-compatible storage service.

```bash
aws s3api create-bucket --bucket "${OC_STORAGE_BUCKET_NAME}" \
  --region "${AWS_REGION:-us-west-2}" \
  --create-bucket-configuration LocationConstraint="${AWS_REGION:-us-west-2}"
```

## IAM Role and Policies

First, generate a unique external ID to use in the trust policy for the IAM role. This helps prevent the confused deputy problem by ensuring that only Snowflake can assume the role.

```bash
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query 'Account' --output text)"
export OC_AWS_USER_ARN=$(jq -r '.storageConfigInfo.userArn' "${WORK_DIR}/catalog-info.json")
export OC_AWS_EXTERNAL_ID=$(jq -r '.storageConfigInfo.externalId' "${WORK_DIR}/catalog-info.json")
```

### Trust Policy

> [!NOTE]
> We will update the trust policy later to allow Open Catalog to assume the role.
> We also add the root user for the AWS account to allow testing the setup from local machine which has access to the AWS account.

Create the IAM role with trust policy:

```bash
cat > "${WORK_DIR}/trust-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Principal": {
        "AWS": [
          "arn:aws:iam::${AWS_ACCOUNT_ID}:root",
          "${OC_AWS_USER_ARN}"
        ]
      },
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "${OC_AWS_EXTERNAL_ID}"
        }
      }
    }
  ]
}
EOF
```

Verify the trust policy:

```bash
jq . "${WORK_DIR}/trust-policy.json"
```


Create the IAM role with the trust policy:

```bash
aws iam create-role \
  --role-name "${OC_STORAGE_AWS_ROLE_NAME}" \
  --assume-role-policy-document "file://${WORK_DIR}/trust-policy.json"
```

### Access Policy

Create the access policy, it defines two statements one for S3 object actions and another for bucket-level actions. This policy allows the role to perform necessary operations on the specified S3 bucket.

```bash
cat > "${WORK_DIR}/s3-access-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:DeleteObject",
        "s3:DeleteObjectVersion"
      ],
      "Resource": "arn:aws:s3:::${OC_STORAGE_BUCKET_NAME}/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": "arn:aws:s3:::${OC_STORAGE_BUCKET_NAME}",
      "Condition": {
        "StringLike": {
          "s3:prefix": [
            "*"
          ]
        }
      }
    }
  ]
}
EOF
```

Verify the access policy:

```bash
jq . "${WORK_DIR}/s3-access-policy.json"
```

Create the policy in AWS:

```bash
aws iam create-policy \
  --policy-name "${OC_STORAGE_AWS_ROLE_POLICY_NAME}" \
  --policy-document "file://${WORK_DIR}/s3-access-policy.json"
```

Finally Attach the policy to the role:

```bash
aws iam attach-role-policy \
  --role-name "${OC_STORAGE_AWS_ROLE_NAME}" \
  --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${OC_STORAGE_AWS_ROLE_POLICY_NAME}"
``` 

## Principal

List existing principals in the Polaris catalog:

```bash
polaris \
    --base-url="${OC_API_URL}/polaris" \
    --access-token="${ACCESS_TOKEN}" \
    principals list
```

Create a principal named `${OC_ADMIN_USER_NAME}`:

> [!NOTE]
> This command creates a new principal in the Polaris catalog, which represents a user or service that can interact with the catalog. The response will include the principal's credentials (`clientId` and `clientSecret`), which can be saved for later use.

```bash
polaris \
    --base-url="${OC_API_URL}/polaris" \
    --access-token="${ACCESS_TOKEN}" \
    principals create "${OC_ADMIN_USER_NAME}" | jq -r . > "${WORK_DIR}/principal.json"
```

Create a Principal role named "${OC_CATALOG_NAME}_admin":

```bash
polaris \
    --base-url="${OC_API_URL}/polaris" \
    --access-token="${ACCESS_TOKEN}" \
    principal-roles create "${OC_CATALOG_NAME}_admin"
```

Now grant that Principal role `${OC_CATALOG_NAME}_admin`  to the Principal `${OC_ADMIN_USER_NAME}`:

```bash
polaris \
    --base-url="${OC_API_URL}/polaris" \
    --access-token="${ACCESS_TOKEN}" \
    principal-roles grant \
      --principal "${OC_ADMIN_USER_NAME}" \
      "${OC_CATALOG_NAME}_admin"
```

## Catalog

Create a catalog role named `${OC_CATALOG_NAME}_catalog_admin`:

```bash
polaris \
    --base-url="${OC_API_URL}/polaris" \
    --access-token="${ACCESS_TOKEN}" \
    catalog-roles create \
    --catalog "${OC_CATALOG_NAME:-polardb}" \
    "${OC_CATALOG_NAME}_catalog_admin"
```

### List

List Catalog Roles in the catalog `${OC_CATALOG_NAME:-polardb}`:

```bash
polaris \
    --base-url="${OC_API_URL}/polaris" \
    --access-token="${ACCESS_TOKEN}" \
    catalog-roles list "${OC_CATALOG_NAME:-polardb}"
```

### Grants

Grant the catalog role `${OC_CATALOG_NAME}_catalog_admin` to the Principal Role `${OC_CATALOG_NAME}_admin`:

```bash
polaris \
    --base-url="${OC_API_URL}/polaris" \
    --access-token="${ACCESS_TOKEN}" \
    catalog-roles grant \
    --catalog "${OC_CATALOG_NAME:-polardb}" \
    --principal-role "${OC_CATALOG_NAME}_admin" \
    "${OC_CATALOG_NAME}_catalog_admin"
```

#### List

List Catalog Roles in the catalog `${OC_CATALOG_NAME:-polardb}` that is assigned to the Principal role `${OC_CATALOG_NAME}_admin`:

```bash
polaris \
    --base-url="${OC_API_URL}/polaris" \
    --access-token="${ACCESS_TOKEN}" \
    catalog-roles list \
    --principal-role "${OC_CATALOG_NAME}_admin" "${OC_CATALOG_NAME:-polardb}"
```

## Privileges

Grant the privilege `CATALOG_MANAGE_CONTENT` to the catalog role `${OC_CATALOG_NAME}_catalog_admin` on the catalog `${OC_CATALOG_NAME:-polardb}`

```bash
polaris \
    --base-url="${OC_API_URL}/polaris" \
    --access-token="${ACCESS_TOKEN}" \
    privileges catalog grant \
    --catalog "${OC_CATALOG_NAME:-polardb}" \
    --catalog-role "${OC_CATALOG_NAME}_catalog_admin" \
    CATALOG_MANAGE_CONTENT
```

Add another role, `TABLE_LIST`, to the catalog role `${OC_CATALOG_NAME}_catalog_admin` on the catalog `${OC_CATALOG_NAME:-polardb}`. This role allows listing tables in the catalog.

```bash
polaris \
    --base-url="${OC_API_URL}/polaris" \
    --access-token="${ACCESS_TOKEN}" \
    privileges catalog grant \
    --catalog "${OC_CATALOG_NAME:-polardb}" \
    --catalog-role "${OC_CATALOG_NAME}_catalog_admin" \
    TABLE_LIST
```

### List

List Catalog Privileges on a Catalog Role,

```bash
polaris \
    --base-url="${OC_API_URL}/polaris" \
    --access-token="${ACCESS_TOKEN}" \
    privileges list \
    --catalog "${OC_CATALOG_NAME:-polardb}" \
    --catalog-role "${OC_CATALOG_NAME}_catalog_admin"
```

## Verify

To verify the setup, let us generate a notebook

```bash
python generate_notebook.py
```

Open the [generated notebook](./notebooks/verify_setup.ipynb) in your Jupyter environment.

## Snowflake Integration

To integrate Snowflake with Open Catalog, you can use the Snowflake CLI to create a connection to the Open Catalog. This allows you to query and manage the Apache Iceberg tables directly from Snowflake.

> [!IMPORTANT]
> You would have set the PRIVATE_KEY_PASSPHRASE in the `.env` file, which is used to authenticate with Snowflake Open Catalog. Unset and set the right one if you are going to use a different passphrase and key based authentication.

Verify if you are able to connect to your Snowflake account:

```bash
snow connection test -c "${SNOWFLAKE_CONNECTION_NAME}"
```

Set the database where you want to create the Iceberg tables to `$SNOWFLAKE_DATABASE`:

e.g. 

```bash
export SNOWFLAKE_DATABASE="kamesh_demos"
```

Extract client ID, client secret, and principal name from the principal JSON file created earlier:

```bash
export CLIENT_ID=$(jq -r '.clientId' "${WORK_DIR}/principal.json")
export CLIENT_SECRET=$(jq -r '.clientSecret' "${WORK_DIR}/principal.json")
```

```bash
snow sql -c "${SNOWFLAKE_CONNECTION_NAME}" \
  --variable="database_name=${SNOWFLAKE_DATABASE}" \
  --variable="schema_name=iceberg" \
  --variable="catalog_name=${OC_CATALOG_NAME:-polardb}" \
  --variable="catalog_uri=${OC_API_URL}/polaris/api/catalog" \
  --variable="client_id=${CLIENT_ID}" \
  --variable="client_secret=${CLIENT_SECRET}" \
  --filename "$PWD/scripts/snowflake_integration.sql"
```

Let us query the iceberg table created in the previous step:

```bash
snow sql  \
  -c "${SNOWFLAKE_CONNECTION_NAME}" \
  -q "select * from kamesh_demos.iceberg.sflabs_oc_pol_demo_fruits"
```

```bash
snow sql  \
  -c "${SNOWFLAKE_CONNECTION_NAME}" \
  -q "select * from kamesh_demos.iceberg.sflabs_oc_pol_demo_penguins limit 10"
```

## Cleanup
To clean up the resources created during this tutorial, you can run the following commands:

Cleanup Open Catalog resources:

1. Revoke the privilege `CATALOG_MANAGE_CONTENT` from the catalog role `${OC_CATALOG_NAME}_catalog_admins`:

```bash
polaris \
    --base-url="${OC_API_URL}/polaris" \
    --access-token="${ACCESS_TOKEN}" \
    privileges catalog revoke \
    --catalog "${OC_CATALOG_NAME:-polardb}" \
    --catalog-role "${OC_CATALOG_NAME}_catalog_admin" \
    CATALOG_MANAGE_CONTENT
```

2. Remove Principal Role `${OC_CATALOG_NAME}_admin` from the catalog role  `${OC_CATALOG_NAME}_catalog_admin`:

```bash
polaris \
    --base-url="${OC_API_URL}/polaris" \
    --access-token="${ACCESS_TOKEN}" \
    catalog-roles grant \
    --catalog "${OC_CATALOG_NAME:-polardb}" \
    --principal-role "${OC_CATALOG_NAME}_admin" \
    "${OC_CATALOG_NAME}_catalog_admin"
```

3. Delete the catalog role `${OC_CATALOG_NAME}_catalog_admin`:

```bash
polaris \
    --base-url="${OC_API_URL}/polaris" \
    --access-token="${ACCESS_TOKEN}" \
    catalog-roles delete \
    --catalog "${OC_CATALOG_NAME:-polardb}" \
    "${OC_CATALOG_NAME}_catalog_admin"
```

4. Revoke the Principal Role `${OC_CATALOG_NAME}_admin` from the Principal `${OC_ADMIN_USER_NAME}`:

```bash
polaris \
    --base-url="${OC_API_URL}/polaris" \
    --access-token="${ACCESS_TOKEN}" \
    principal-roles revoke \
      --principal "${OC_ADMIN_USER_NAME}" \
      "${OC_CATALOG_NAME}_admin"
```

5. Delete the Principal Role `${OC_CATALOG_NAME}_admin`:

```bash
polaris \
    --base-url="${OC_API_URL}/polaris" \
    --access-token="${ACCESS_TOKEN}" \
    principal-roles delete "${OC_CATALOG_NAME}_admin"
```

6. Delete the Principal `${OC_ADMIN_USER_NAME}`:

```bash
polaris \
    --base-url="${OC_API_URL}/polaris" \
    --access-token="${ACCESS_TOKEN}" \
    principals delete "${OC_ADMIN_USER_NAME}"
```

>[!NOTE]
> The namespaces, tables and the holding catalog is not deleted. Clean them up if needed via the OpenCatalog UI.

Clean up all AWS resources created for the Open Catalog integration:

Ensure you have the `$AWS_ACCOUNT_ID` set,

```bash
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query 'Account' --output text)"
```

1. Delete the S3 bucket and its contents:

```bash
aws s3 rb "s3://${OC_STORAGE_BUCKET_NAME}" --force
```

2. Detach the IAM role policy from the role:

```bash
aws iam detach-role-policy \
  --role-name "${OC_STORAGE_AWS_ROLE_NAME}" \
  --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${OC_STORAGE_AWS_ROLE_POLICY_NAME}"
```

3. Delete the IAM role:

```bash
aws iam delete-role \
  --role-name "${OC_STORAGE_AWS_ROLE_NAME}"
```

4. Delete the IAM policy:

```bash
aws iam delete-policy \
  --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${OC_STORAGE_AWS_ROLE_POLICY_NAME}"
```


Lastly empty the resources created in the `${WORK_DIR}` directory:

```bash
find "${WORK_DIR:?}" -name "*.json" -type f -delete
```


## References

- [Apache Polaris (Incubating)](https://polaris.apache.org/)
- [Snowflake Open Catalog](https://other-docs.snowflake.com/en/opencatalog/overview)
- [Apache Iceberg](https://iceberg.apache.org/)
- [PyIceberg](https://py.iceberg.apache.org/api/)
- [Polaris CLI Documentation](https://polaris.apache.org/in-dev/0.9.0/command-line-interface/)