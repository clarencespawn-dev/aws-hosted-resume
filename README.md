# AWS Hosted Resume

A fully serverless resume website deployed on AWS — built as a practical portfolio project while transitioning from technical support into cloud and platform engineering.

**Live site → [https://d278wvzbvtd1hh.cloudfront.net](https://d278wvzbvtd1hh.cloudfront.net)**

---

## What this project demonstrates

- Infrastructure as Code using **Terraform** — the entire stack provisions with `terraform apply`
- Serverless architecture on **AWS Always Free tier** — no EC2, no API Gateway, $0/month
- Least-privilege **IAM** roles scoped to exactly the actions each Lambda needs
- **CloudFront + S3** static hosting with Origin Access Control (private bucket, no public S3)
- Live **visitor counter** backed by DynamoDB atomic increments
- **Contact form** that emails submissions via SES, with the visitor's address as Reply-To
- Terraform `templatefile()` injects Lambda Function URLs into the HTML at deploy time — no manual copy-paste

---

## Architecture

```
Browser ──HTTPS──► CloudFront (PriceClass_200) ──OAC──► S3 (private)
   │                                                      index.html
   ├──GET──► Lambda Function URL ──► visitor-counter Lambda ──► DynamoDB
   │                                                             (atomic ADD)
   └──POST─► Lambda Function URL ──► contact-form Lambda ──► SES ──► inbox
```

| Service | Role | Free tier |
|---|---|---|
| S3 | Stores the static site | ~$0/mo at this size |
| CloudFront | HTTPS CDN, Oceania edge locations | 1 TB / 10M req per month |
| Lambda | Visitor counter + contact form | 1M requests per month |
| DynamoDB | Visitor count persistence | 25 RCU/WCU forever |
| SES | Contact form email delivery | 3K emails/month |
| IAM | Execution roles for each function | Free |

---

## Project structure

```
aws-hosted-resume/
├── main.tf                    # Full Terraform config — all resources in one file
├── terraform.tfvars.example   # Copy to terraform.tfvars and fill in email addresses
├── .gitignore
├── lambda_visitor_counter.py  # DynamoDB atomic counter
├── lambda_contact_form.py     # Input validation + SES send
└── website/
    └── index.html.tmpl        # Resume HTML — Lambda URLs injected by templatefile()
```

---

## Deploy it yourself

### Prerequisites

- Terraform ≥ 1.6
- AWS CLI v2, configured with credentials (`aws configure`)
- An AWS account (free tier is enough)

### Steps

```bash
# 1. Clone
git clone https://github.com/clarencespawn-dev/aws-hosted-resume.git
cd aws-hosted-resume

# 2. Set your email addresses
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set sender_email and recipient_email

# 3. Deploy
terraform init
terraform plan
terraform apply   # ~10 min, mostly CloudFront

# 4. Check your inbox and click the SES verification link
# 5. Open the resume_url printed in the outputs
```

After apply, Terraform prints your CloudFront URL and Lambda Function URLs. The HTML is already wired up — no manual steps.

### Updating the site

```bash
# Edit website/index.html.tmpl or a Lambda .py file, then:
terraform apply
# Terraform re-uploads the HTML and runs a CloudFront invalidation automatically
```

### Tear down

```bash
BUCKET=$(terraform output -raw s3_bucket_name)
aws s3 rm s3://$BUCKET --recursive
terraform destroy
```

---

## About this project

I'm a Senior Technical Support Specialist at Simpro Software in Auckland, currently studying for the **AWS Certified Cloud Practitioner (CLF-C02)** exam and building hands-on cloud projects alongside that study. This resume is one of them.

Next on the roadmap: AWS Solutions Architect Associate → HashiCorp Terraform Associate.

**GitHub:** [github.com/clarencespawn-dev](https://github.com/clarencespawn-dev)
**Email:** clarencepaulus777@gmail.com
