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

Completed setting up Snowflake CLI and Open Catalog to auth with Key Pair. If not done, please follow the steps in the [Open Catalog KeyPair](https://other-docs.snowflake.com/en/LIMITEDACCESS/opencatalog/key-pair-auth#before-you-begin).

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


## S3 bucket
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
```

### Trust Policy

> [!NOTE]
> We will update the trust policy later to allow Open Catalog to assume the role.

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
          "arn:aws:iam::${AWS_ACCOUNT_ID}:root"
        ]
      },
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "will be updated"
        }
      }
    }
  ]
}
EOF
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

Finally, export the role ARN to use in the Open Catalog CLI commands:

```bash
export OC_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${OC_STORAGE_AWS_ROLE_NAME}"
```

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

> [!NOTE]
> **DEBUG**
> ```bash
> http -v POST  "${OC_API_URL}/polaris/api/management/v1/catalogs" \
>   Accept:application/json \
>   Authorization:"Bearer $ACCESS_TOKEN"  < "$PWD/work/payload.json"
> ```

Update AWS IAM Role trust policy to allow Open Catalog to assume the role:

Get Catalog Information:

```bash
polaris \
  --base-url="${OC_API_URL}/polaris" \
    --access-token="${ACCESS_TOKEN}" \
    catalogs list | jq --arg catalog_name "${OC_CATALOG_NAME:-polardb}" '. | select(.name==$catalog_name)' > "${WORK_DIR}/catalog-info.json"
  ```

Update the trust policy to allow Open Catalog to assume the role:

```bash
export OC_AWS_USER_ARN=$(jq -r '.storageConfigInfo.userArn' "${WORK_DIR}/catalog-info.json")
export AWS_EXTERNAL_ID=$(jq -r '.storageConfigInfo.externalId' "${WORK_DIR}/catalog-info.json")
```

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
          "sts:ExternalId": "${AWS_EXTERNAL_ID}"
        }
      }
    }
  ]
}
EOF
```

```bash
aws iam update-assume-role-policy \
  --role-name "${OC_STORAGE_AWS_ROLE_NAME}" \
  --policy-document "file://${WORK_DIR}/trust-policy.json"
``` 

## Principal

List all principals, (Errors out if no principals are created yet):

> [!NOTE]
> **DEBUG**
> This is not working and unable to list principals
> ```bash
> Exception when communicating with the Polaris server. 1 validation error for Principal
> name
> Value error, must validate the regular expression /^(?!\s*[s|S][y|Y][s|S][t|T][e|E][m|M]\$).*$/ [type=value_error, input_value='SYSTEM$USER_PRINCIPAL_A3...FB5CBC7313E140E30E9A29A', input_type=str]
>    For further information visit https://errors.pydantic.dev/2.11/v/value_error
> ```
>

```bash
polaris \
    --base-url="${OC_API_URL}/polaris" \
    --access-token="${ACCESS_TOKEN}" \
    principals list
```

Create a principal named `${OC_CATALOG_NAME}-admin`:

```bash
polaris \
    --base-url="${OC_API_URL}/polaris" \
    --access-token="${ACCESS_TOKEN}" \
    principals create "${OC_ADMIN_USER_NAME}" | jq -r . > "${WORK_DIR}/principal.json"
```

Create a Principal role named "${OC_CATALOG_NAME}-admin":

```bash
polaris \
    --base-url="${OC_API_URL}/polaris" \
    --access-token="${ACCESS_TOKEN}" \
    principal-roles create "${OC_CATALOG_NAME}-admin"
```

Now grant that Principal role `${OC_CATALOG_NAME}-admin`  to the Principal `${OC_ADMIN_USER_NAME}`:

```bash
polaris \
    --base-url="${OC_API_URL}/polaris" \
    --access-token="${ACCESS_TOKEN}" \
    principal-roles grant \
      --principal "${OC_ADMIN_USER_NAME}" \
      "${OC_CATALOG_NAME}-admin"
```

## Catalog

Create a catalog role named `${OC_CATALOG_NAME}_catalog_admins`:

```bash
polaris \
    --base-url="${OC_API_URL}/polaris" \
    --access-token="${ACCESS_TOKEN}" \
    catalog-roles create \
    --catalog "${OC_CATALOG_NAME:-polardb}" \
    ${OC_CATALOG_NAME}_catalog_admins
```

Grant the catalog role `${OC_CATALOG_NAME}_catalog_admins` to the Principal Role `${OC_CATALOG_NAME}-admin`:

```bash
polaris \
    --base-url="${OC_API_URL}/polaris" \
    --access-token="${ACCESS_TOKEN}" \
    catalog-roles grant \
    --catalog "${OC_CATALOG_NAME:-polardb}" \
    --principal-role "${OC_CATALOG_NAME}-admin" \
    ${OC_CATALOG_NAME}_catalog_admins
```

## Privileges

Grant the privilege `CATALOG_MANAGE_CONTENT` to the catalog role `${OC_CATALOG_NAME}_catalog_admins` on the catalog `${OC_CATALOG_NAME:-polardb}`

```bash
polaris \
    --base-url="${OC_API_URL}/polaris" \
    --access-token="${ACCESS_TOKEN}" \
    privileges catalog grant \
    --catalog "${OC_CATALOG_NAME:-polardb}" \
    --catalog-role "${OC_CATALOG_NAME}_catalog_admins" \
    CATALOG_MANAGE_CONTENT
```

## Verify

To verify the setup, let us generate a notebook

```bash
python generate_notebook.py
```

Open the [generated notebook](./notebooks/verify_setup.ipynb) in your Jupyter environment.


## References

- [Apache Polaris (Incubating)](https://polaris.apache.org/)
- [Snowflake Open Catalog](https://other-docs.snowflake.com/en/opencatalog/overview)
- [Apache Iceberg](https://iceberg.apache.org/)
- [PyIceberg](https://py.iceberg.apache.org/api/)
- [Polaris CLI Documentation](https://polaris.apache.org/in-dev/0.9.0/command-line-interface/)