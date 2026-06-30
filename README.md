# AWS Hosted Resume

A fully serverless resume website deployed on AWS — built as a hands-on portfolio project while transitioning from technical support into cloud and platform engineering.

**Live site → [https://d278wvzbvtd1hh.cloudfront.net](https://d278wvzbvtd1hh.cloudfront.net)**

---

## What this project demonstrates

- Infrastructure as Code using **Terraform** — the entire stack provisions with `terraform apply`, no manual console steps
- Serverless architecture on the **AWS Free Tier** — no EC2, no servers to patch
- Least-privilege **IAM** roles, scoped to exactly the actions each Lambda needs
- **CloudFront + S3** static hosting with Origin Access Control — the bucket stays private, CloudFront is the only reader
- **API Gateway + Lambda** backing two live features: a visitor counter and a working contact form
- **DynamoDB** atomic counter for visitor tracking
- **SES** email delivery, with the visitor's address set as Reply-To so replies go straight to them
- **AWS Budgets + SNS** — a $1 USD monthly cost alert wired to email, so spend never goes unnoticed
- Terraform `templatefile()` injects the live API endpoints into the HTML at deploy time — no manual copy-pasting URLs after every change

---

## Architecture

```
Browser ──HTTPS──► CloudFront ──OAC──► S3 (private bucket)
   │                                    index.html
   ├──GET──► API Gateway ──► visitor-counter Lambda ──► DynamoDB (atomic ADD)
   │
   └──POST─► API Gateway ──► contact-form Lambda ──► SES ──► inbox

AWS Budgets ──► SNS ──► email alert if monthly spend exceeds $1 USD
```

| Service | Role | Free tier |
|---|---|---|
| S3 | Stores the static site | ~$0/mo at this size |
| CloudFront | HTTPS CDN | 1 TB / 10M requests per month, no expiry |
| API Gateway | REST endpoints for both Lambdas | 1M calls/month for 12 months |
| Lambda | Visitor counter + contact form logic | 1M requests/month, no expiry |
| DynamoDB | Visitor count persistence | 25 RCU/WCU, no expiry |
| SES | Contact form email delivery | 3,000 emails/month for 12 months |
| AWS Budgets + SNS | Cost alerting | Free |

---

## Project structure

```
aws-hosted-resume/
├── main.tf                    Full Terraform config — every AWS resource
├── terraform.tfvars.example   Copy to terraform.tfvars, fill in your email
├── .gitignore                 Excludes state files, tfvars, build artifacts
├── lambda_visitor_counter.py  DynamoDB atomic counter
├── lambda_contact_form.py     Input validation + SES send
└── website/
    └── index.html.tmpl        Resume HTML — API endpoints injected by templatefile()
```

`terraform.tfstate`, `.terraform/`, and `terraform.tfvars` are intentionally not in this repo — state files contain resource IDs and should never be committed, and tfvars holds personal email addresses.

---

## Deploy it yourself

### Prerequisites

- Terraform ≥ 1.6
- AWS CLI v2, configured with credentials (`aws configure`)
- An AWS account (free tier covers this entirely)

### Steps

```bash
git clone https://github.com/clarencespawn-dev/aws-hosted-resume.git
cd aws-hosted-resume

cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: set sender_email and recipient_email

terraform init
terraform plan
terraform apply   # ~10 minutes, mostly CloudFront propagation
```

After apply, Terraform prints your CloudFront URL and both API Gateway endpoints. The HTML is already wired up with them — no manual steps.

Check your inbox for the SES verification email and click the link before testing the contact form.

### Updating the site

```bash
# Edit website/index.html.tmpl or either Lambda's .py file, then:
terraform apply
# Terraform detects the change, re-uploads the HTML, and invalidates the CloudFront cache
```

### Tear down

```bash
BUCKET=$(terraform output -raw s3_bucket_name)
aws s3 rm s3://$BUCKET --recursive
terraform destroy
```

---

## About this project

I'm a Senior Technical Support Specialist at Simpro Software in Auckland — four years as the first responder to SaaS production outages. I'm now studying for the **AWS Certified Cloud Practitioner (CLF-C02)** exam and building real infrastructure alongside that study, rather than just reading about it. This resume is one of those projects: deployed, monitored for cost, and actually used.

Next on the certification roadmap: AWS Solutions Architect Associate → HashiCorp Terraform Associate.

**GitHub:** [github.com/clarencespawn-dev](https://github.com/clarencespawn-dev)
**Email:** clarencepaulus777@gmail.com
