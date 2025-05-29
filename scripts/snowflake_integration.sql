use database <%database_name%>;
create schema if not exists <%schema_name%>;
use schema <%schema_name%>;

CREATE OR REPLACE CATALOG INTEGRATION sflabs_oc_pol_demo
  CATALOG_SOURCE = POLARIS
  TABLE_FORMAT = ICEBERG
  CATALOG_NAMESPACE = '<%catalog_name%>'
  REST_CONFIG = (
    CATALOG_URI = '<%catalog_uri%>'
    CATALOG_NAME = '<%catalog_name%>'
    ACCESS_DELEGATION_MODE = VENDED_CREDENTIALS
  )
  REST_AUTHENTICATION = (
    TYPE = OAUTH
    OAUTH_CLIENT_ID = '<%client_id%>'
    OAUTH_CLIENT_SECRET = '<%client_secret%>'
    OAUTH_ALLOWED_SCOPES = ('PRINCIPAL_ROLE:ALL')
  )
  ENABLED = TRUE;

-- create iceberg table named fruits
CREATE OR REPLACE ICEBERG TABLE sflabs_oc_pol_demo_fruits
  CATALOG = 'sflabs_oc_pol_demo'
  CATALOG_NAMESPACE = 'demo'
  CATALOG_TABLE_NAME = 'fruits'
  AUTO_REFRESH = TRUE;

-- create iceberg table named fruits
CREATE OR REPLACE ICEBERG TABLE sflabs_oc_pol_demo_penguins
  CATALOG = 'sflabs_oc_pol_demo'
  CATALOG_NAMESPACE = 'wildlife'
  CATALOG_TABLE_NAME = 'penguins'
  AUTO_REFRESH = TRUE;
  