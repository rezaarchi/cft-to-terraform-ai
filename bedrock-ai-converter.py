#!/usr/bin/env python3
import json
import yaml
import boto3
import sys
import re
from pathlib import Path

# Add CloudFormation YAML tag support - ALL intrinsic functions
yaml.SafeLoader.add_constructor('!Ref', lambda loader, node: {'Ref': loader.construct_scalar(node)})
yaml.SafeLoader.add_constructor('!Sub', lambda loader, node: {'Fn::Sub': loader.construct_scalar(node)})
yaml.SafeLoader.add_constructor('!GetAtt', lambda loader, node: {'Fn::GetAtt': loader.construct_scalar(node).split('.')})
yaml.SafeLoader.add_constructor('!Join', lambda loader, node: {'Fn::Join': loader.construct_sequence(node)})
yaml.SafeLoader.add_constructor('!Select', lambda loader, node: {'Fn::Select': loader.construct_sequence(node)})
yaml.SafeLoader.add_constructor('!GetAZs', lambda loader, node: {'Fn::GetAZs': loader.construct_scalar(node)})
yaml.SafeLoader.add_constructor('!Split', lambda loader, node: {'Fn::Split': loader.construct_sequence(node)})
yaml.SafeLoader.add_constructor('!Base64', lambda loader, node: {'Fn::Base64': loader.construct_scalar(node)})
yaml.SafeLoader.add_constructor('!Cidr', lambda loader, node: {'Fn::Cidr': loader.construct_sequence(node)})
yaml.SafeLoader.add_constructor('!ImportValue', lambda loader, node: {'Fn::ImportValue': loader.construct_scalar(node)})
yaml.SafeLoader.add_constructor('!FindInMap', lambda loader, node: {'Fn::FindInMap': loader.construct_sequence(node)})
yaml.SafeLoader.add_constructor('!If', lambda loader, node: {'Fn::If': loader.construct_sequence(node)})
yaml.SafeLoader.add_constructor('!Equals', lambda loader, node: {'Fn::Equals': loader.construct_sequence(node)})
yaml.SafeLoader.add_constructor('!Not', lambda loader, node: {'Fn::Not': loader.construct_sequence(node)})
yaml.SafeLoader.add_constructor('!And', lambda loader, node: {'Fn::And': loader.construct_sequence(node)})
yaml.SafeLoader.add_constructor('!Or', lambda loader, node: {'Fn::Or': loader.construct_sequence(node)})

class BedrockConverter:
    def __init__(self, region='us-east-1'):
        self.bedrock = boto3.client('bedrock-runtime', region_name=region)
        self.model_id = 'us.amazon.nova-pro-v1:0'
    
    def call_bedrock(self, prompt):
        """Call Bedrock Nova Pro"""
        try:
            response = self.bedrock.converse(
                modelId=self.model_id,
                messages=[{
                    "role": "user",
                    "content": [{"text": prompt}]
                }],
                inferenceConfig={
                    "maxTokens": 4096,
                    "temperature": 0.1,
                    "topP": 0.9
                }
            )
            
            text = response['output']['message']['content'][0]['text']
            
            # Strip markdown code blocks
            text = re.sub(r'^```(?:hcl|terraform|tf)?\s*\n', '', text, flags=re.MULTILINE)
            text = re.sub(r'\n```\s*$', '', text, flags=re.MULTILINE)
            text = re.sub(r'^```$', '', text, flags=re.MULTILINE)
            
            return text.strip()
        except Exception as e:
            print(f"Bedrock error: {e}")
            raise
    
    def convert(self, cft_file, output_dir):
        Path(output_dir).mkdir(exist_ok=True)
        
        with open(cft_file) as f:
            template = yaml.safe_load(f)
        
        prompt = f"""Convert this CloudFormation template to Terraform HCL.

CloudFormation Template:
{json.dumps(template, indent=2)}

CRITICAL Requirements:
1. Convert ALL resources to Terraform with correct syntax
2. Declare ALL required data sources (aws_availability_zones, aws_caller_identity, etc.)
3. Handle intrinsic functions correctly:
   - Fn::GetAZs → data.aws_availability_zones.available.names
   - Ref → resource references
   - Fn::Sub → string interpolation with ${{}} syntax
4. Use CORRECT Terraform resource syntax for AWS provider v5+

SECURITY GROUPS - CRITICAL:
When converting CloudFormation SecurityGroupIngress with SourceSecurityGroupId, you MUST place source_security_group_id INSIDE the ingress block, NOT at the resource level.

WRONG - DO NOT DO THIS:
resource "aws_security_group" "example" {{
  vpc_id = aws_vpc.main.id
  source_security_group_id = aws_security_group.alb.id  # WRONG LOCATION
}}

CORRECT - DO THIS:
resource "aws_security_group" "example" {{
  vpc_id = aws_vpc.main.id
  
  ingress {{
    from_port                = 80
    to_port                  = 80
    protocol                 = "tcp"
    source_security_group_id = aws_security_group.alb.id  # CORRECT - inside ingress block
  }}
}}

REMEMBER: source_security_group_id is a property of ingress/egress blocks, NOT of the aws_security_group resource itself.

IAM ROLES - CRITICAL:
- DO NOT use managed_policy_arns in aws_iam_role
- Instead, create separate aws_iam_role_policy_attachment resources
- Example:
  
resource "aws_iam_role" "example" {{
  name               = "example-role"
  assume_role_policy = jsonencode({{
    Version = "2012-10-17"
    Statement = [{{
      Effect = "Allow"
      Principal = {{
        Service = "ec2.amazonaws.com"
      }}
      Action = "sts:AssumeRole"
    }}]
  }})
}}

resource "aws_iam_role_policy_attachment" "example_ssm" {{
  role       = aws_iam_role.example.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}}

resource "aws_iam_role_policy_attachment" "example_cloudwatch" {{
  role       = aws_iam_role.example.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}}

VARIABLES:
- For Parameters with NoEcho:true, create variable with sensitive=true and default=""
- Add comment above: # TODO: Provide secure value via tfvars or environment variable

LAUNCH TEMPLATES:
- Security groups go in network_interfaces block with security_groups (plural)
- DO NOT use vpc_security_group_ids at root level
- user_data must be base64encode() of the script content

RDS INSTANCES:
- Use vpc_security_group_ids (plural) for the list of security group IDs
- NOT security_group_ids or vpc_security_groups

LOAD BALANCERS:
- Use security_groups (plural) for the list of security group IDs

OTHER:
- Do NOT include provider, terraform, or backend blocks
- Do NOT reference external files (no templatefile())
- Inline all user data scripts directly
- Ensure all resource references are declared
- Use proper Terraform HCL syntax throughout
- Pay attention to singular vs plural attribute names (security_groups vs security_group_ids)

Output ONLY valid Terraform resources and data sources. No provider blocks, no terraform blocks, no markdown formatting, no explanations."""
        
        print(f"Calling Bedrock to convert {cft_file}...")
        tf_code = self.call_bedrock(prompt)
        
        output_file = Path(output_dir) / f"{Path(cft_file).stem}.tf"
        output_file.write_text(tf_code)
        
        # Build report without nested triple quotes
        original_template = open(cft_file).read()
        report_content = "# AI-Powered CloudFormation to Terraform Conversion\n\n"
        report_content += f"## Source Template\n**File:** `{cft_file}`\n\n"
        report_content += "**Converted:** Using AWS Bedrock Nova Pro (us.amazon.nova-pro-v1:0)\n\n"
        report_content += "---\n\n## Generated Terraform Code\n\n```hcl\n"
        report_content += tf_code
        report_content += "\n```\n\n---\n\n## Original CloudFormation Template\n\n```yaml\n"
        report_content += original_template
        report_content += "\n```\n"
        
        report = Path(output_dir) / "CONVERSION_REPORT.md"
        report.write_text(report_content)
        
        print(f"✓ Converted {cft_file}")
        return True

if __name__ == '__main__':
    region = 'us-east-1'
    if '--region' in sys.argv:
        idx = sys.argv.index('--region')
        if idx + 1 < len(sys.argv):
            region = sys.argv[idx + 1]
    
    converter = BedrockConverter(region=region)
    converter.convert(sys.argv[1], sys.argv[2])
