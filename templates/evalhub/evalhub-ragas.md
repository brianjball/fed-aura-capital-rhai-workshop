# EvalHub Ragas Integration Guide

## What is Ragas in EvalHub?

Ragas (Retrieval Augmented Generation Assessment) evaluates **RAG pipeline quality** - not raw LLM performance like `lm_evaluation_harness`. It uses the LLM as a judge to score how well a RAG system retrieves context and generates answers.

| Aspect | lm_evaluation_harness | ragas |
|---|---|---|
| Evaluates | Raw LLM text generation | RAG pipeline outputs |
| Input data | Built-in benchmarks (ARC, MMLU, etc.) | User-provided JSONL with RAG Q&A |
| Judge model | N/A (compares vs ground truth) | Uses the LLM itself as judge |
| Embeddings | Not needed | Needed for some metrics |
| Key question | "How smart is this LLM?" | "Is my RAG grounding answers correctly?" |

## Available Benchmarks

- `ragas_rag_default` - 4 metrics: answer_relevancy, context_precision, faithfulness, context_recall
- `ragas_rag_full` - 8+ metrics: adds semantic_similarity, factual_correctness, noise_sensitivity, etc.

## Dataset Format

Ragas requires a JSONL file with these columns:

```jsonl
{"user_input": "What is X?", "response": "X is...", "retrieved_contexts": ["context1", "context2"], "reference": "Ground truth answer"}
```

- `user_input` - the question asked to the RAG system
- `response` - what the RAG system answered
- `retrieved_contexts` - array of context passages the retriever found
- `reference` - ground truth reference answer

If your dataset uses different column names, use the `column_map` parameter to remap them.

## Why It Doesn't Work From the UI

The RHOAI 3.5 dashboard UI exposes `test_data_ref` (S3 data source) only as a benchmark-level field in the job submission API. The UI form doesn't have input fields for S3 bucket/key/secret configuration for the Ragas provider. This is a gap in the current UI - `lm_evaluation_harness` doesn't need external datasets (benchmarks are built-in), so the UI was designed primarily for that provider.

**Workaround**: Submit via the EvalHub REST API (curl/SDK). The job still appears in the RHOAI dashboard for tracking and viewing results.

## Prerequisites

1. **EvalHub CR** with `ragas` in the providers list:

```yaml
spec:
  providers:
    - ragas
    - lm-evaluation-harness
    # ...
```

2. **Dataset in MinIO/S3** - upload your JSONL dataset:

```bash
# Port-forward MinIO
oc port-forward svc/minio-service -n <namespace> 9099:9000 &

# Create bucket and upload
export AWS_ACCESS_KEY_ID=minio
export AWS_SECRET_ACCESS_KEY=<your-secret>
aws --endpoint-url http://localhost:9099 s3 mb s3://eval-data
aws --endpoint-url http://localhost:9099 s3 cp dataset.jsonl s3://eval-data/ragas/dataset.jsonl
```

3. **S3 credentials secret** in the tenant namespace:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: eval-s3-credentials
  namespace: <tenant-namespace>
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: "minio"
  AWS_SECRET_ACCESS_KEY: "<your-secret>"
  AWS_DEFAULT_REGION: "us-east-1"
  AWS_S3_ENDPOINT: "http://minio-service.<namespace>.svc.cluster.local:9000"
```

4. **Model auth secret** with the API key for the judge LLM.

## Submitting via curl

```bash
TOKEN=$(oc whoami -t)

curl -sk -X POST \
  "https://<evalhub-route>/api/v1/evaluations/jobs" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Tenant: <tenant-namespace>" \
  -H "X-User: admin" \
  -d '{
    "name": "rag-quality-eval",
    "model": {
      "url": "https://<model-endpoint>",
      "name": "<model-name>",
      "auth": {
        "secret_ref": "<model-auth-secret>"
      }
    },
    "benchmarks": [
      {
        "id": "ragas_rag_default",
        "provider_id": "ragas",
        "parameters": {
          "temperature": 0.1,
          "max_tokens": 4096,
          "max_workers": 1,
          "metrics": ["faithfulness", "context_precision", "context_recall"]
        },
        "test_data_ref": {
          "s3": {
            "bucket": "eval-data",
            "key": "ragas",
            "secret_ref": "eval-s3-credentials"
          }
        }
      }
    ]
  }'
```

## Using envsubst with the eval template

```bash
export MODEL_URL="https://litemaas.rhoai.rh-aiservices-bu.com"
export MODEL_NAME="Qwen3.6-35B-A3B"
export MODEL_AUTH_SECRET="qwen36-35b-a3b-api-key"
export S3_CREDENTIALS_SECRET="eval-s3-credentials"

envsubst < eval-ragas-rag.yaml | yq -o json | \
  curl -sk -X POST "https://<evalhub-route>/api/v1/evaluations/jobs" \
    -H "Authorization: Bearer $(oc whoami -t)" \
    -H "Content-Type: application/json" \
    -H "X-Tenant: wskp-user1" \
    -H "X-User: admin" \
    -d @-
```

## Checking job status

```bash
# Via API
curl -sk "https://<evalhub-route>/api/v1/evaluations/jobs/<job-id>" \
  -H "Authorization: Bearer $(oc whoami -t)" \
  -H "X-Tenant: <tenant-namespace>"

# Via pod logs
oc logs <pod-name> -n <tenant-namespace> -c adapter --tail=20

# Via the RHOAI dashboard UI
# Navigate to: Evaluations > wskp-user1 - results appear automatically
```

## Parameters Reference

| Parameter | Type | Default | Description |
|---|---|---|---|
| metrics | array | benchmark default | Which metrics to run |
| temperature | number | null | Sampling temperature for judge LLM |
| max_tokens | integer | null | Max tokens - use 4096+ for Ragas |
| max_workers | integer | 1 | Parallel workers (1-10) |
| embedding_model | string | same as model | Model name for embeddings endpoint |
| embedding_url | string | same as model URL | Separate embeddings endpoint |
| column_map | object | null | Remap dataset columns to Ragas names |
| data_path | string | auto | Explicit path to dataset file |

## Known Issues and Workarounds

### 1. Metrics requiring embeddings fail with MaaS endpoints

Metrics like `answer_relevancy` and `semantic_similarity` need an `/v1/embeddings` endpoint. If your model gateway doesn't support embeddings, exclude these metrics:

```json
"metrics": ["faithfulness", "context_precision", "context_recall"]
```

### 2. IncompleteOutputException with low max_tokens

Ragas uses the `instructor` library for structured output extraction. If `max_tokens` is too low (e.g., 512), the model output gets truncated and parsing fails. Use `max_tokens: 4096` or higher.

### 3. Container image compatibility (v0.5.0 vs latest)

The `v0.5.0` image has a bug where `EvalHubOpenAILLM` is incompatible with ragas >= 0.4.x collections metrics. The `latest` image fixes this. To update:

```bash
# Patch the provider ConfigMap
oc get cm evalhub-provider-ragas -n redhat-ods-applications -o json | \
  python3 -c "import sys,json; d=json.load(sys.stdin); d['data']['ragas.yaml']=d['data']['ragas.yaml'].replace('v0.5.0','latest'); json.dump(d,sys.stdout)" | \
  oc replace -f -
```

Note: The TrustyAI operator may revert this change during reconciliation. Scale the operator down temporarily if needed.

### 4. TLS certificate mismatch with ExternalName services

When using ExternalName services (e.g., MaaS gateway), the k8s service FQDN doesn't match the external TLS certificate. Use the actual external hostname in the model URL instead:

```json
"url": "https://litemaas.rhoai.rh-aiservices-bu.com"
```

Not:

```json
"url": "https://qwen36-35b-a3b.external-models.svc.cluster.local"
```

## Submitting via EvalHub SDK/CLI

The EvalHub SDK provides both a CLI and a Python client that wrap the REST API. Install from PyPI - the package name is `eval-hub-sdk`.

### Install

```bash
# CLI + client
pip install "eval-hub-sdk[cli]"

# Python client only (no CLI binary)
pip install "eval-hub-sdk[client]"
```

Requires Python 3.11+. Verify with `evalhub version`.

### Configure

```bash
# Set the EvalHub endpoint
evalhub config set base_url https://$(oc get route evalhub -n redhat-ods-applications -o jsonpath='{.spec.host}')

# Auth token from OpenShift
evalhub config set token $(oc whoami -t)

# Tenant namespace where the eval runs
evalhub config set tenant wskp-user1
```

For CI/CD, you can also use environment variables:

```bash
export EVALHUB_BASE_URL="https://evalhub.apps.cluster.example.com"
export EVALHUB_TOKEN="$(oc whoami -t)"
```

### Submit a Ragas evaluation (CLI)

Use `envsubst` to fill in the template placeholders and pipe into the CLI:

```bash
export MODEL_URL="https://litemaas.rhoai.rh-aiservices-bu.com"
export MODEL_NAME="Qwen3.6-35B-A3B"
export MODEL_AUTH_SECRET="qwen36-35b-a3b-api-key"
export S3_CREDENTIALS_SECRET="eval-s3-credentials"

envsubst < eval-ragas-rag.yaml | evalhub eval run --config -
```

You can also pass `--wait` to block until the job finishes:

```bash
envsubst < eval-ragas-rag.yaml | evalhub eval run --config - --wait
```

### CLI job management

```bash
evalhub eval status                              # List all jobs
evalhub eval status --status running             # Filter by status
evalhub eval status <job-id>                     # Inspect specific job
evalhub eval status <job-id> --watch             # Watch until completion
evalhub eval results <job-id>                    # View results
evalhub eval results <job-id> --format csv       # Export as CSV
evalhub eval cancel <job-id>                     # Cancel a running job
```

### Submit a Ragas evaluation (Python SDK)

For programmatic usage (automation, notebooks, CI pipelines):

```python
from evalhub import SyncEvalHubClient, ModelConfig
from evalhub.models.api import BenchmarkConfig, JobSubmissionRequest

benchmark = BenchmarkConfig(
    id="ragas_rag_default",
    provider_id="ragas",
    parameters={
        "temperature": 0.1,
        "max_tokens": 4096,
        "max_workers": 1,
        "metrics": ["faithfulness", "context_precision", "context_recall"],
    },
    test_data_ref={
        "s3": {
            "bucket": "eval-data",
            "key": "ragas",
            "secret_ref": "eval-s3-credentials",
        }
    },
)

request = JobSubmissionRequest(
    name="rag-quality-eval",
    model=ModelConfig(
        url="https://litemaas.rhoai.rh-aiservices-bu.com",
        name="Qwen3.6-35B-A3B",
        auth={"secret_ref": "qwen36-35b-a3b-api-key"},
    ),
    benchmarks=[benchmark],
)

token = "sha256~..."  # from oc whoami -t

with SyncEvalHubClient(
    base_url="https://evalhub.apps.cluster.example.com",
    auth_token=token,
) as client:
    job = client.jobs.submit(request, tenant="wskp-user1")
    print(f"Job submitted: {job.id}, Status: {job.state}")

    # Block until done (timeout in seconds)
    final = client.jobs.wait_for_completion(job.id, timeout=900)
    print(f"Final status: {final.state}")
```

An async variant (`AsyncEvalHubClient`) is also available with the same API.

### Eval template reference (eval-ragas-rag.yaml)

```yaml
name: "rag-quality-eval"
model:
  url: "${MODEL_URL}"
  name: "${MODEL_NAME}"
  auth:
    secret_ref: "${MODEL_AUTH_SECRET}"
benchmarks:
  - id: ragas_rag_default
    provider_id: ragas
    parameters:
      temperature: "0.1"
      max_tokens: "4096"
      max_workers: "2"
      metrics: '["faithfulness", "context_precision", "context_recall"]'
    test_data_ref:
      s3:
        bucket: "eval-data"
        key: "ragas"
        secret_ref: "${S3_CREDENTIALS_SECRET}"
```

The template uses `envsubst` placeholders (`${VAR}`) so you can swap model endpoints, secrets, and S3 configs without editing the file directly. Export the variables and pipe through `envsubst`.

## Example Results

Ragas evaluation of FedAura Capital mortgage lending RAG dataset:

- Model: Qwen3.6-35B-A3B (via MaaS)
- Metric: faithfulness
- Score: 0.8833 (88.3%)
- Records: 20
- Duration: ~10 minutes
