# Go Lambda Plugin

Comprehensive Go Lambda development with production-ready patterns for AWS.

## Features

- **Runtime**: `provided.al2023` (recommended) for smaller footprint and longer support
- **Architecture**: ARM64 (Graviton2) for 34% better price-performance
- **SDK**: AWS SDK for Go v2 with proper patterns
- **Infrastructure**: AWS CDK v2 with TypeScript

## Skills

### `/go-lambda-builder`

Generate production-ready Go Lambda functions with:

- All valid handler signatures
- Event types (API Gateway, S3, SQS, DynamoDB Streams, SNS, EventBridge, Kinesis)
- AWS SDK v2 integration (DynamoDB, S3, SQS, Secrets Manager, SSM)
- Error handling patterns (wrapping, custom types, AWS errors)
- Structured logging with slog
- Cold start optimization
- CDK infrastructure patterns
- Migration guide from go1.x

## Quick Start

```go
package main

import (
    "context"
    "log/slog"
    "os"

    "github.com/aws/aws-lambda-go/events"
    "github.com/aws/aws-lambda-go/lambda"
    "github.com/aws/aws-sdk-go-v2/config"
    "github.com/aws/aws-sdk-go-v2/service/dynamodb"
)

var dbClient *dynamodb.Client

func init() {
    cfg, _ := config.LoadDefaultConfig(context.Background())
    dbClient = dynamodb.NewFromConfig(cfg)
}

func handler(ctx context.Context, event events.APIGatewayProxyRequest) (events.APIGatewayProxyResponse, error) {
    slog.Info("processing", "requestId", event.RequestContext.RequestID)
    return events.APIGatewayProxyResponse{StatusCode: 200}, nil
}

func main() {
    lambda.Start(handler)
}
```

## Build Commands

```bash
# ARM64 build (recommended)
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build \
    -ldflags="-s -w" \
    -tags lambda.norpc \
    -o bootstrap main.go

# Create deployment package
zip function.zip bootstrap
```

## CDK Setup

```typescript
import * as go from '@aws-cdk/aws-lambda-go-alpha';
import * as lambda from 'aws-cdk-lib/aws-lambda';

const fn = new go.GoFunction(this, 'Handler', {
  entry: '../cmd/api',
  architecture: lambda.Architecture.ARM_64,
  runtime: lambda.Runtime.PROVIDED_AL2023,
  memorySize: 1024,
  timeout: cdk.Duration.seconds(30),
});
```

## Requirements

- Go 1.21+ (for slog)
- AWS CDK v2
- `@aws-cdk/aws-lambda-go-alpha` package
