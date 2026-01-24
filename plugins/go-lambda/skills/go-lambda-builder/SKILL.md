---
name: go-lambda-builder
description: Generate production-ready Go Lambda functions with provided.al2023 runtime, ARM64/Graviton2 architecture, AWS SDK v2 integration, and CDK infrastructure. Use when building new Lambda functions in Go or migrating from go1.x runtime.
---

# Go Lambda Builder - Complete Reference

## Overview

This skill generates production-ready Go Lambda functions optimized for:
- **Runtime**: `provided.al2023` (recommended) or `provided.al2`
- **Architecture**: ARM64 (Graviton2) for 34% better price-performance
- **SDK**: AWS SDK for Go v2
- **Infrastructure**: AWS CDK v2 with TypeScript

## Quick Start Template

### Minimal Lambda Function

```go
package main

import (
	"context"
	"github.com/aws/aws-lambda-go/lambda"
)

func handler(ctx context.Context) (string, error) {
	return "Hello from Lambda!", nil
}

func main() {
	lambda.Start(handler)
}
```

### Production Lambda Function

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

var (
	dbClient  *dynamodb.Client
	tableName string
	logger    *slog.Logger
)

func init() {
	// Initialize logger
	logger = slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))

	// Load AWS config
	cfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		logger.Error("failed to load AWS config", "error", err)
		panic(err)
	}

	// Initialize clients (reused across invocations)
	dbClient = dynamodb.NewFromConfig(cfg)
	tableName = os.Getenv("TABLE_NAME")
}

func handler(ctx context.Context, event events.APIGatewayProxyRequest) (events.APIGatewayProxyResponse, error) {
	logger.Info("processing request",
		"requestId", event.RequestContext.RequestID,
		"path", event.Path,
		"method", event.HTTPMethod,
	)

	// Your business logic here

	return events.APIGatewayProxyResponse{
		StatusCode: 200,
		Headers:    map[string]string{"Content-Type": "application/json"},
		Body:       `{"message": "success"}`,
	}, nil
}

func main() {
	lambda.Start(handler)
}
```

---

## Handler Function Signatures

Lambda handlers must follow specific patterns. The handler may accept 0-2 arguments and return 0-2 values.

### Valid Signatures

```go
// No input, no output
func ()

// Error only
func () error

// Output and error
func () (TOut, error)

// Input and error
func (TIn) error

// Input, output, and error
func (TIn) (TOut, error)

// Context only
func (context.Context) error

// Context and output
func (context.Context) (TOut, error)

// Context and input
func (context.Context, TIn) error

// Context, input, output (RECOMMENDED)
func (context.Context, TIn) (TOut, error)
```

### Handler Rules

1. **Context must be first** - If accepting context, it must be the first parameter
2. **Error must be last** - If returning error, it must be the last return value
3. **JSON-compatible types** - Input/output must be JSON-unmarshalable
4. **Use context.Context** - Always accept context for cancellation and deadlines

---

## Event Types (aws-lambda-go/events)

### API Gateway (REST API)

```go
import "github.com/aws/aws-lambda-go/events"

func handler(ctx context.Context, event events.APIGatewayProxyRequest) (events.APIGatewayProxyResponse, error) {
	// Request fields
	method := event.HTTPMethod                    // GET, POST, etc.
	path := event.Path                            // /users/123
	pathParams := event.PathParameters            // map[string]string{"id": "123"}
	queryParams := event.QueryStringParameters   // map[string]string{"page": "1"}
	headers := event.Headers                      // map[string]string
	body := event.Body                            // string (JSON body)
	isBase64 := event.IsBase64Encoded            // bool
	requestID := event.RequestContext.RequestID  // unique request ID

	return events.APIGatewayProxyResponse{
		StatusCode:        200,
		Headers:           map[string]string{"Content-Type": "application/json"},
		Body:              `{"status": "ok"}`,
		IsBase64Encoded:   false,
	}, nil
}
```

### API Gateway (HTTP API v2)

```go
func handler(ctx context.Context, event events.APIGatewayV2HTTPRequest) (events.APIGatewayV2HTTPResponse, error) {
	method := event.RequestContext.HTTP.Method
	path := event.RequestContext.HTTP.Path

	return events.APIGatewayV2HTTPResponse{
		StatusCode: 200,
		Body:       `{"status": "ok"}`,
	}, nil
}
```

### Application Load Balancer (ALB)

```go
func handler(ctx context.Context, event events.ALBTargetGroupRequest) (events.ALBTargetGroupResponse, error) {
	return events.ALBTargetGroupResponse{
		StatusCode:        200,
		StatusDescription: "200 OK",
		Headers:           map[string]string{"Content-Type": "application/json"},
		Body:              `{"status": "ok"}`,
		IsBase64Encoded:   false,
	}, nil
}
```

### S3 Event

```go
func handler(ctx context.Context, event events.S3Event) error {
	for _, record := range event.Records {
		bucket := record.S3.Bucket.Name
		key := record.S3.Object.Key
		size := record.S3.Object.Size
		eventType := record.EventName // e.g., "ObjectCreated:Put"

		slog.Info("processing S3 event",
			"bucket", bucket,
			"key", key,
			"size", size,
			"event", eventType,
		)
	}
	return nil
}
```

### SQS Event

```go
func handler(ctx context.Context, event events.SQSEvent) (events.SQSEventResponse, error) {
	var batchItemFailures []events.SQSBatchItemFailure

	for _, record := range event.Records {
		messageID := record.MessageId
		body := record.Body

		if err := processMessage(ctx, body); err != nil {
			// Report failed message for retry
			batchItemFailures = append(batchItemFailures, events.SQSBatchItemFailure{
				ItemIdentifier: messageID,
			})
		}
	}

	return events.SQSEventResponse{
		BatchItemFailures: batchItemFailures,
	}, nil
}
```

### DynamoDB Streams

```go
func handler(ctx context.Context, event events.DynamoDBEvent) error {
	for _, record := range event.Records {
		eventName := record.EventName // INSERT, MODIFY, REMOVE

		switch eventName {
		case "INSERT":
			newImage := record.Change.NewImage
			// Process new item
		case "MODIFY":
			oldImage := record.Change.OldImage
			newImage := record.Change.NewImage
			// Process modification
		case "REMOVE":
			oldImage := record.Change.OldImage
			// Process deletion
		}
	}
	return nil
}
```

### SNS Event

```go
func handler(ctx context.Context, event events.SNSEvent) error {
	for _, record := range event.Records {
		message := record.SNS.Message
		subject := record.SNS.Subject
		topicArn := record.SNS.TopicArn

		slog.Info("received SNS message",
			"topic", topicArn,
			"subject", subject,
		)
	}
	return nil
}
```

### EventBridge (CloudWatch Events)

```go
func handler(ctx context.Context, event events.CloudWatchEvent) error {
	source := event.Source           // e.g., "aws.ec2"
	detailType := event.DetailType   // e.g., "EC2 Instance State-change Notification"
	detail := event.Detail           // json.RawMessage

	return nil
}
```

### Kinesis

```go
func handler(ctx context.Context, event events.KinesisEvent) error {
	for _, record := range event.Records {
		data := record.Kinesis.Data  // []byte (base64 decoded)
		partitionKey := record.Kinesis.PartitionKey
		sequenceNumber := record.Kinesis.SequenceNumber

		// Process record
	}
	return nil
}
```

### Scheduled Event (Cron)

```go
type ScheduledEvent struct {
	Version    string          `json:"version"`
	ID         string          `json:"id"`
	DetailType string          `json:"detail-type"`
	Source     string          `json:"source"`
	Account    string          `json:"account"`
	Time       string          `json:"time"`
	Region     string          `json:"region"`
	Resources  []string        `json:"resources"`
	Detail     json.RawMessage `json:"detail"`
}

func handler(ctx context.Context, event ScheduledEvent) error {
	slog.Info("scheduled invocation", "time", event.Time)
	return nil
}
```

---

## Lambda Context

The Lambda context provides runtime information about the invocation.

```go
import (
	"context"
	"github.com/aws/aws-lambda-go/lambdacontext"
)

func handler(ctx context.Context, event any) error {
	// Get Lambda-specific context
	lc, ok := lambdacontext.FromContext(ctx)
	if ok {
		functionName := lc.InvokedFunctionArn
		requestID := lc.AwsRequestID
		logGroup := lc.LogGroupName
		logStream := lc.LogStreamName
		memoryLimit := lc.MemoryLimitInMB

		slog.Info("lambda context",
			"function", functionName,
			"requestId", requestID,
			"memoryLimit", memoryLimit,
		)
	}

	// Check remaining time before timeout
	deadline, ok := ctx.Deadline()
	if ok {
		remaining := time.Until(deadline)
		if remaining < 5*time.Second {
			slog.Warn("low remaining time", "remaining", remaining)
		}
	}

	return nil
}
```

---

## AWS SDK v2 Integration

### Configuration Loading

```go
import (
	"context"
	"github.com/aws/aws-sdk-go-v2/config"
)

// Default configuration (recommended)
cfg, err := config.LoadDefaultConfig(context.Background())

// With specific region
cfg, err := config.LoadDefaultConfig(context.Background(),
	config.WithRegion("us-east-1"),
)

// With custom endpoint (for local testing)
cfg, err := config.LoadDefaultConfig(context.Background(),
	config.WithEndpointResolverWithOptions(
		aws.EndpointResolverWithOptionsFunc(func(service, region string, options ...interface{}) (aws.Endpoint, error) {
			return aws.Endpoint{URL: "http://localhost:8000"}, nil
		}),
	),
)
```

### DynamoDB Operations

```go
import (
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/feature/dynamodb/attributevalue"
	"github.com/aws/aws-sdk-go-v2/feature/dynamodb/expression"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
)

// Define struct with DynamoDB tags
type User struct {
	PK        string `dynamodbav:"PK"`
	SK        string `dynamodbav:"SK"`
	ID        string `dynamodbav:"id"`
	Email     string `dynamodbav:"email"`
	Name      string `dynamodbav:"name"`
	CreatedAt string `dynamodbav:"createdAt"`
}

// PutItem
func putUser(ctx context.Context, client *dynamodb.Client, user User) error {
	item, err := attributevalue.MarshalMap(user)
	if err != nil {
		return fmt.Errorf("marshal user: %w", err)
	}

	_, err = client.PutItem(ctx, &dynamodb.PutItemInput{
		TableName: aws.String(tableName),
		Item:      item,
	})
	return err
}

// GetItem
func getUser(ctx context.Context, client *dynamodb.Client, pk, sk string) (*User, error) {
	result, err := client.GetItem(ctx, &dynamodb.GetItemInput{
		TableName: aws.String(tableName),
		Key: map[string]types.AttributeValue{
			"PK": &types.AttributeValueMemberS{Value: pk},
			"SK": &types.AttributeValueMemberS{Value: sk},
		},
	})
	if err != nil {
		return nil, fmt.Errorf("get item: %w", err)
	}
	if result.Item == nil {
		return nil, nil // Not found
	}

	var user User
	if err := attributevalue.UnmarshalMap(result.Item, &user); err != nil {
		return nil, fmt.Errorf("unmarshal user: %w", err)
	}
	return &user, nil
}

// Query with expression builder
func queryUsersByEmail(ctx context.Context, client *dynamodb.Client, email string) ([]User, error) {
	keyCond := expression.Key("GSI1PK").Equal(expression.Value("EMAIL#" + email))

	expr, err := expression.NewBuilder().
		WithKeyCondition(keyCond).
		Build()
	if err != nil {
		return nil, fmt.Errorf("build expression: %w", err)
	}

	result, err := client.Query(ctx, &dynamodb.QueryInput{
		TableName:                 aws.String(tableName),
		IndexName:                 aws.String("GSI1"),
		KeyConditionExpression:    expr.KeyCondition(),
		ExpressionAttributeNames:  expr.Names(),
		ExpressionAttributeValues: expr.Values(),
	})
	if err != nil {
		return nil, fmt.Errorf("query: %w", err)
	}

	var users []User
	if err := attributevalue.UnmarshalListOfMaps(result.Items, &users); err != nil {
		return nil, fmt.Errorf("unmarshal users: %w", err)
	}
	return users, nil
}

// UpdateItem with expression builder
func updateUserName(ctx context.Context, client *dynamodb.Client, pk, sk, newName string) error {
	update := expression.Set(expression.Name("name"), expression.Value(newName))
	update.Set(expression.Name("updatedAt"), expression.Value(time.Now().Format(time.RFC3339)))

	expr, err := expression.NewBuilder().
		WithUpdate(update).
		Build()
	if err != nil {
		return fmt.Errorf("build expression: %w", err)
	}

	_, err = client.UpdateItem(ctx, &dynamodb.UpdateItemInput{
		TableName: aws.String(tableName),
		Key: map[string]types.AttributeValue{
			"PK": &types.AttributeValueMemberS{Value: pk},
			"SK": &types.AttributeValueMemberS{Value: sk},
		},
		UpdateExpression:          expr.Update(),
		ExpressionAttributeNames:  expr.Names(),
		ExpressionAttributeValues: expr.Values(),
	})
	return err
}
```

### S3 Operations

```go
import (
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/feature/s3/manager"
)

// Upload file
func uploadFile(ctx context.Context, client *s3.Client, bucket, key string, data []byte) error {
	_, err := client.PutObject(ctx, &s3.PutObjectInput{
		Bucket:      aws.String(bucket),
		Key:         aws.String(key),
		Body:        bytes.NewReader(data),
		ContentType: aws.String("application/json"),
	})
	return err
}

// Upload large file with manager
func uploadLargeFile(ctx context.Context, client *s3.Client, bucket, key string, reader io.Reader) error {
	uploader := manager.NewUploader(client, func(u *manager.Uploader) {
		u.PartSize = 10 * 1024 * 1024 // 10MB parts
	})

	_, err := uploader.Upload(ctx, &s3.PutObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String(key),
		Body:   reader,
	})
	return err
}

// Download file
func downloadFile(ctx context.Context, client *s3.Client, bucket, key string) ([]byte, error) {
	result, err := client.GetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String(key),
	})
	if err != nil {
		return nil, err
	}
	defer result.Body.Close()

	return io.ReadAll(result.Body)
}

// Generate presigned URL
func generatePresignedURL(ctx context.Context, client *s3.Client, bucket, key string, expiry time.Duration) (string, error) {
	presignClient := s3.NewPresignClient(client)

	req, err := presignClient.PresignGetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String(key),
	}, s3.WithPresignExpires(expiry))
	if err != nil {
		return "", err
	}

	return req.URL, nil
}
```

### SQS Operations

```go
import "github.com/aws/aws-sdk-go-v2/service/sqs"

// Send message
func sendMessage(ctx context.Context, client *sqs.Client, queueURL, body string) error {
	_, err := client.SendMessage(ctx, &sqs.SendMessageInput{
		QueueUrl:    aws.String(queueURL),
		MessageBody: aws.String(body),
	})
	return err
}

// Send message with delay
func sendDelayedMessage(ctx context.Context, client *sqs.Client, queueURL, body string, delaySecs int32) error {
	_, err := client.SendMessage(ctx, &sqs.SendMessageInput{
		QueueUrl:     aws.String(queueURL),
		MessageBody:  aws.String(body),
		DelaySeconds: delaySecs,
	})
	return err
}

// Receive messages (for polling - not needed with Lambda event source)
func receiveMessages(ctx context.Context, client *sqs.Client, queueURL string) ([]string, error) {
	result, err := client.ReceiveMessage(ctx, &sqs.ReceiveMessageInput{
		QueueUrl:            aws.String(queueURL),
		MaxNumberOfMessages: 10,
		WaitTimeSeconds:     20, // Long polling
	})
	if err != nil {
		return nil, err
	}

	var messages []string
	for _, msg := range result.Messages {
		messages = append(messages, *msg.Body)

		// Delete after processing
		_, _ = client.DeleteMessage(ctx, &sqs.DeleteMessageInput{
			QueueUrl:      aws.String(queueURL),
			ReceiptHandle: msg.ReceiptHandle,
		})
	}
	return messages, nil
}
```

### Secrets Manager

```go
import "github.com/aws/aws-sdk-go-v2/service/secretsmanager"

var secretCache = make(map[string]string)

func getSecret(ctx context.Context, client *secretsmanager.Client, secretName string) (string, error) {
	// Check cache first
	if cached, ok := secretCache[secretName]; ok {
		return cached, nil
	}

	result, err := client.GetSecretValue(ctx, &secretsmanager.GetSecretValueInput{
		SecretId: aws.String(secretName),
	})
	if err != nil {
		return "", fmt.Errorf("get secret: %w", err)
	}

	secret := *result.SecretString
	secretCache[secretName] = secret
	return secret, nil
}
```

### SSM Parameter Store

```go
import "github.com/aws/aws-sdk-go-v2/service/ssm"

func getParameter(ctx context.Context, client *ssm.Client, name string) (string, error) {
	result, err := client.GetParameter(ctx, &ssm.GetParameterInput{
		Name:           aws.String(name),
		WithDecryption: aws.Bool(true),
	})
	if err != nil {
		return "", err
	}
	return *result.Parameter.Value, nil
}
```

---

## Error Handling

### Error Wrapping

```go
import (
	"errors"
	"fmt"
)

// Sentinel errors
var (
	ErrNotFound     = errors.New("not found")
	ErrUnauthorized = errors.New("unauthorized")
	ErrValidation   = errors.New("validation failed")
)

// Wrap errors with context
func getUser(ctx context.Context, id string) (*User, error) {
	user, err := db.GetItem(ctx, id)
	if err != nil {
		return nil, fmt.Errorf("get user %s: %w", id, err)
	}
	if user == nil {
		return nil, fmt.Errorf("user %s: %w", id, ErrNotFound)
	}
	return user, nil
}

// Check error types
func handler(ctx context.Context, event Request) (Response, error) {
	user, err := getUser(ctx, event.UserID)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return Response{StatusCode: 404, Body: "User not found"}, nil
		}
		if errors.Is(err, ErrUnauthorized) {
			return Response{StatusCode: 401, Body: "Unauthorized"}, nil
		}
		// Log and return 500 for unexpected errors
		slog.Error("unexpected error", "error", err)
		return Response{StatusCode: 500, Body: "Internal error"}, nil
	}
	// ...
}
```

### Custom Error Types

```go
type ValidationError struct {
	Field   string
	Message string
}

func (e *ValidationError) Error() string {
	return fmt.Sprintf("validation error on %s: %s", e.Field, e.Message)
}

type APIError struct {
	StatusCode int
	Message    string
	Err        error
}

func (e *APIError) Error() string {
	return e.Message
}

func (e *APIError) Unwrap() error {
	return e.Err
}

// Usage
func validateRequest(req Request) error {
	if req.Email == "" {
		return &ValidationError{Field: "email", Message: "required"}
	}
	return nil
}

func handler(ctx context.Context, event Request) (Response, error) {
	if err := validateRequest(event); err != nil {
		var validationErr *ValidationError
		if errors.As(err, &validationErr) {
			return Response{
				StatusCode: 400,
				Body:       fmt.Sprintf("Invalid %s: %s", validationErr.Field, validationErr.Message),
			}, nil
		}
	}
	// ...
}
```

### AWS SDK Error Handling

```go
import (
	"github.com/aws/smithy-go"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
)

func handleDynamoDBError(err error) error {
	var apiErr smithy.APIError
	if errors.As(err, &apiErr) {
		switch apiErr.ErrorCode() {
		case "ConditionalCheckFailedException":
			return ErrConflict
		case "ResourceNotFoundException":
			return ErrNotFound
		case "ProvisionedThroughputExceededException":
			return ErrThrottled
		}
	}
	return err
}

// For specific DynamoDB error types
func putItemSafe(ctx context.Context, client *dynamodb.Client, item map[string]types.AttributeValue) error {
	_, err := client.PutItem(ctx, &dynamodb.PutItemInput{
		TableName:           aws.String(tableName),
		Item:                item,
		ConditionExpression: aws.String("attribute_not_exists(PK)"),
	})
	if err != nil {
		var condErr *types.ConditionalCheckFailedException
		if errors.As(err, &condErr) {
			return fmt.Errorf("item already exists: %w", ErrConflict)
		}
		return fmt.Errorf("put item: %w", err)
	}
	return nil
}
```

---

## Logging

### Structured Logging with slog (Go 1.21+)

```go
import (
	"log/slog"
	"os"
)

var logger *slog.Logger

func init() {
	// JSON logging for CloudWatch
	logger = slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: getLogLevel(),
	}))
	slog.SetDefault(logger)
}

func getLogLevel() slog.Level {
	switch os.Getenv("LOG_LEVEL") {
	case "DEBUG":
		return slog.LevelDebug
	case "WARN":
		return slog.LevelWarn
	case "ERROR":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}

func handler(ctx context.Context, event events.APIGatewayProxyRequest) (events.APIGatewayProxyResponse, error) {
	// Add request context to all logs
	requestLogger := logger.With(
		"requestId", event.RequestContext.RequestID,
		"path", event.Path,
		"method", event.HTTPMethod,
	)

	requestLogger.Info("processing request")

	// Log with additional fields
	requestLogger.Info("user action",
		"userId", event.PathParameters["userId"],
		"action", "view",
	)

	// Log errors with stack context
	if err := doSomething(); err != nil {
		requestLogger.Error("operation failed",
			"error", err,
			"operation", "doSomething",
		)
	}

	requestLogger.Debug("request details", "body", event.Body)

	return events.APIGatewayProxyResponse{StatusCode: 200}, nil
}
```

---

## Cold Start Optimization

### Connection Pooling in init()

```go
var (
	// Initialize expensive resources once
	dbClient     *dynamodb.Client
	s3Client     *s3.Client
	sqsClient    *sqs.Client
	httpClient   *http.Client
)

func init() {
	// Load config once
	cfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		panic(err)
	}

	// Create clients (reused across invocations)
	dbClient = dynamodb.NewFromConfig(cfg)
	s3Client = s3.NewFromConfig(cfg)
	sqsClient = sqs.NewFromConfig(cfg)

	// Custom HTTP client with connection pooling
	httpClient = &http.Client{
		Transport: &http.Transport{
			MaxIdleConns:        100,
			MaxIdleConnsPerHost: 100,
			IdleConnTimeout:     90 * time.Second,
		},
		Timeout: 30 * time.Second,
	}
}
```

### Binary Size Optimization

Build with stripped symbols:

```bash
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build \
    -ldflags="-s -w" \
    -tags lambda.norpc \
    -o bootstrap main.go
```

Flags explained:
- `-ldflags="-s -w"`: Strip symbol table and debug info (20-30% smaller)
- `-tags lambda.norpc`: Exclude RPC support (smaller binary)
- `CGO_ENABLED=0`: Static compilation (no libc dependency)

### Memory Configuration

- Lambda allocates CPU proportionally to memory
- 1,769 MB = 1 full vCPU
- For CPU-bound Go functions, consider 1024-1769 MB
- For I/O-bound functions, 512 MB is often sufficient
- Use AWS Lambda Power Tuning to find optimal configuration

---

## Project Structure

### Recommended Layout

```
my-lambda-project/
├── cmd/
│   ├── api/
│   │   └── main.go           # API Gateway handler
│   ├── processor/
│   │   └── main.go           # SQS processor
│   └── scheduled/
│       └── main.go           # Scheduled task
├── internal/
│   ├── domain/
│   │   └── user.go           # Domain models
│   ├── repository/
│   │   └── user_repo.go      # DynamoDB operations
│   ├── service/
│   │   └── user_service.go   # Business logic
│   └── handler/
│       └── api_handler.go    # HTTP handler logic
├── pkg/
│   └── middleware/
│       └── logging.go        # Shared utilities
├── infrastructure/
│   ├── bin/
│   │   └── infrastructure.ts # CDK app entry
│   ├── lib/
│   │   └── stack.ts          # CDK stack
│   ├── cdk.json
│   ├── package.json
│   └── tsconfig.json
├── go.mod
├── go.sum
├── Makefile
└── README.md
```

### Makefile

```makefile
.PHONY: build clean deploy test

# Variables
FUNCTIONS := api processor scheduled
BUILD_DIR := build
GOFLAGS := -ldflags="-s -w" -tags lambda.norpc

# Build all functions
build: clean
	@for fn in $(FUNCTIONS); do \
		echo "Building $$fn..."; \
		GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build $(GOFLAGS) \
			-o $(BUILD_DIR)/$$fn/bootstrap ./cmd/$$fn; \
	done

# Clean build artifacts
clean:
	rm -rf $(BUILD_DIR)

# Run tests
test:
	go test -v -race ./...

# Run tests with coverage
test-coverage:
	go test -v -race -coverprofile=coverage.out ./...
	go tool cover -html=coverage.out -o coverage.html

# Deploy infrastructure
deploy: build
	cd infrastructure && npm run cdk deploy

# Local development
dev:
	go run ./cmd/api

# Lint
lint:
	golangci-lint run ./...
```

---

## CDK Infrastructure (TypeScript)

### Basic Lambda Stack

```typescript
import * as cdk from 'aws-cdk-lib';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as apigateway from 'aws-cdk-lib/aws-apigateway';
import * as go from '@aws-cdk/aws-lambda-go-alpha';
import { Construct } from 'constructs';

export class MyLambdaStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // DynamoDB Table
    const table = new dynamodb.TableV2(this, 'Table', {
      partitionKey: { name: 'PK', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'SK', type: dynamodb.AttributeType.STRING },
      billing: dynamodb.Billing.onDemand(),
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      globalSecondaryIndexes: [
        {
          indexName: 'GSI1',
          partitionKey: { name: 'GSI1PK', type: dynamodb.AttributeType.STRING },
          sortKey: { name: 'GSI1SK', type: dynamodb.AttributeType.STRING },
        },
      ],
    });

    // Lambda Function
    const fn = new go.GoFunction(this, 'ApiHandler', {
      entry: '../cmd/api',
      architecture: lambda.Architecture.ARM_64,
      runtime: lambda.Runtime.PROVIDED_AL2023,
      memorySize: 1024,
      timeout: cdk.Duration.seconds(30),
      environment: {
        TABLE_NAME: table.tableName,
        LOG_LEVEL: 'INFO',
      },
      bundling: {
        goBuildFlags: ['-ldflags="-s -w"', '-tags lambda.norpc'],
      },
      tracing: lambda.Tracing.ACTIVE,
    });

    // Grant permissions
    table.grantReadWriteData(fn);

    // API Gateway
    const api = new apigateway.RestApi(this, 'Api', {
      restApiName: 'My API',
      deployOptions: {
        stageName: 'prod',
        tracingEnabled: true,
      },
    });

    const integration = new apigateway.LambdaIntegration(fn);

    // Routes
    const users = api.root.addResource('users');
    users.addMethod('GET', integration);
    users.addMethod('POST', integration);

    const user = users.addResource('{userId}');
    user.addMethod('GET', integration);
    user.addMethod('PUT', integration);
    user.addMethod('DELETE', integration);

    // Outputs
    new cdk.CfnOutput(this, 'ApiUrl', {
      value: api.url,
    });
  }
}
```

### Event-Driven Stack (SQS + DynamoDB Streams)

```typescript
import * as sqs from 'aws-cdk-lib/aws-sqs';
import * as lambdaEventSources from 'aws-cdk-lib/aws-lambda-event-sources';

export class EventDrivenStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // Dead Letter Queue
    const dlq = new sqs.Queue(this, 'DLQ', {
      queueName: 'my-dlq',
      retentionPeriod: cdk.Duration.days(14),
    });

    // Main Queue
    const queue = new sqs.Queue(this, 'Queue', {
      queueName: 'my-queue',
      visibilityTimeout: cdk.Duration.seconds(300), // 6x function timeout
      deadLetterQueue: {
        queue: dlq,
        maxReceiveCount: 3,
      },
    });

    // SQS Processor Lambda
    const processor = new go.GoFunction(this, 'Processor', {
      entry: '../cmd/processor',
      architecture: lambda.Architecture.ARM_64,
      runtime: lambda.Runtime.PROVIDED_AL2023,
      memorySize: 512,
      timeout: cdk.Duration.seconds(50),
      reservedConcurrentExecutions: 10, // Limit concurrency
    });

    // Add SQS event source
    processor.addEventSource(new lambdaEventSources.SqsEventSource(queue, {
      batchSize: 10,
      maxBatchingWindow: cdk.Duration.seconds(5),
      reportBatchItemFailures: true,
    }));

    // DynamoDB table with streams
    const table = new dynamodb.TableV2(this, 'Table', {
      partitionKey: { name: 'PK', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'SK', type: dynamodb.AttributeType.STRING },
      dynamoStream: dynamodb.StreamViewType.NEW_AND_OLD_IMAGES,
    });

    // Stream Processor Lambda
    const streamProcessor = new go.GoFunction(this, 'StreamProcessor', {
      entry: '../cmd/stream-processor',
      architecture: lambda.Architecture.ARM_64,
      runtime: lambda.Runtime.PROVIDED_AL2023,
      memorySize: 512,
      timeout: cdk.Duration.seconds(60),
    });

    // Add DynamoDB Streams event source
    streamProcessor.addEventSource(new lambdaEventSources.DynamoEventSource(table, {
      startingPosition: lambda.StartingPosition.LATEST,
      batchSize: 100,
      maxBatchingWindow: cdk.Duration.seconds(5),
      retryAttempts: 3,
      onFailure: new lambdaEventSources.SqsDestination(dlq),
    }));
  }
}
```

### Scheduled Lambda

```typescript
import * as events from 'aws-cdk-lib/aws-events';
import * as targets from 'aws-cdk-lib/aws-events-targets';

// Scheduled function
const scheduled = new go.GoFunction(this, 'Scheduled', {
  entry: '../cmd/scheduled',
  architecture: lambda.Architecture.ARM_64,
  runtime: lambda.Runtime.PROVIDED_AL2023,
  memorySize: 256,
  timeout: cdk.Duration.minutes(5),
});

// Run every hour
new events.Rule(this, 'HourlyRule', {
  schedule: events.Schedule.rate(cdk.Duration.hours(1)),
  targets: [new targets.LambdaFunction(scheduled)],
});

// Run at specific time (UTC)
new events.Rule(this, 'DailyRule', {
  schedule: events.Schedule.cron({
    minute: '0',
    hour: '10',
  }),
  targets: [new targets.LambdaFunction(scheduled)],
});
```

### Function URL (Direct HTTPS)

```typescript
const fn = new go.GoFunction(this, 'Handler', {
  entry: '../cmd/api',
  architecture: lambda.Architecture.ARM_64,
  runtime: lambda.Runtime.PROVIDED_AL2023,
});

// Add function URL
const fnUrl = fn.addFunctionUrl({
  authType: lambda.FunctionUrlAuthType.NONE, // Public
  cors: {
    allowedOrigins: ['*'],
    allowedMethods: [lambda.HttpMethod.ALL],
    allowedHeaders: ['*'],
  },
});

new cdk.CfnOutput(this, 'FunctionUrl', {
  value: fnUrl.url,
});
```

---

## Migration from go1.x to provided.al2023

### Before (go1.x)

```go
// go1.x used aws-lambda-go automatically
package main

import (
	"github.com/aws/aws-lambda-go/lambda"
)

func handler() (string, error) {
	return "Hello", nil
}

func main() {
	lambda.Start(handler)
}
```

Build: `GOOS=linux go build -o main main.go`

### After (provided.al2023)

```go
// Same code works!
package main

import (
	"github.com/aws/aws-lambda-go/lambda"
)

func handler() (string, error) {
	return "Hello", nil
}

func main() {
	lambda.Start(handler)
}
```

Build: `GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -ldflags="-s -w" -o bootstrap main.go`

### Key Changes

| Aspect | go1.x | provided.al2023 |
|--------|-------|-----------------|
| Runtime | `go1.x` | `provided.al2023` |
| Handler | `main` (function name) | `bootstrap` (binary name) |
| Binary name | `main` | `bootstrap` |
| Architecture | x86_64 only | x86_64 or arm64 |
| GOARCH | `amd64` | `arm64` (recommended) |

### CDK Migration

```typescript
// Before
new lambda.Function(this, 'Handler', {
  runtime: lambda.Runtime.GO_1_X,
  handler: 'main',
  code: lambda.Code.fromAsset('path/to/main'),
});

// After
new go.GoFunction(this, 'Handler', {
  entry: '../cmd/api',
  runtime: lambda.Runtime.PROVIDED_AL2023,
  architecture: lambda.Architecture.ARM_64,
});
```

---

## Testing

### Unit Test Example

```go
package handler

import (
	"context"
	"testing"

	"github.com/aws/aws-lambda-go/events"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestHandler(t *testing.T) {
	tests := []struct {
		name           string
		event          events.APIGatewayProxyRequest
		expectedStatus int
		expectedBody   string
	}{
		{
			name: "successful request",
			event: events.APIGatewayProxyRequest{
				HTTPMethod: "GET",
				Path:       "/users/123",
				PathParameters: map[string]string{
					"userId": "123",
				},
			},
			expectedStatus: 200,
			expectedBody:   `{"id":"123"}`,
		},
		{
			name: "missing user ID",
			event: events.APIGatewayProxyRequest{
				HTTPMethod: "GET",
				Path:       "/users/",
			},
			expectedStatus: 400,
			expectedBody:   `{"error":"missing user ID"}`,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctx := context.Background()
			resp, err := handler(ctx, tt.event)

			require.NoError(t, err)
			assert.Equal(t, tt.expectedStatus, resp.StatusCode)
			assert.JSONEq(t, tt.expectedBody, resp.Body)
		})
	}
}
```

### Mocking AWS Services

```go
package repository

import (
	"context"
	"testing"

	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/stretchr/testify/mock"
)

// Mock DynamoDB client
type MockDynamoDBClient struct {
	mock.Mock
}

func (m *MockDynamoDBClient) GetItem(ctx context.Context, params *dynamodb.GetItemInput, optFns ...func(*dynamodb.Options)) (*dynamodb.GetItemOutput, error) {
	args := m.Called(ctx, params)
	return args.Get(0).(*dynamodb.GetItemOutput), args.Error(1)
}

func TestGetUser(t *testing.T) {
	mockClient := new(MockDynamoDBClient)
	repo := NewUserRepository(mockClient, "test-table")

	mockClient.On("GetItem", mock.Anything, mock.Anything).Return(
		&dynamodb.GetItemOutput{
			Item: map[string]types.AttributeValue{
				"PK":    &types.AttributeValueMemberS{Value: "USER#123"},
				"SK":    &types.AttributeValueMemberS{Value: "PROFILE"},
				"email": &types.AttributeValueMemberS{Value: "test@example.com"},
			},
		},
		nil,
	)

	user, err := repo.GetUser(context.Background(), "123")

	require.NoError(t, err)
	assert.Equal(t, "test@example.com", user.Email)
	mockClient.AssertExpectations(t)
}
```

---

## Best Practices Summary

### DO

- Use `provided.al2023` runtime with ARM64 architecture
- Initialize AWS clients in `init()` for connection reuse
- Use `context.Context` for all operations
- Wrap errors with `fmt.Errorf("context: %w", err)`
- Use structured logging (slog with JSON)
- Define small, focused interfaces
- Use table-driven tests
- Build with `-ldflags="-s -w"` for smaller binaries

### DON'T

- Use global `map[string]interface{}` for DynamoDB (causes type corruption)
- Ignore context cancellation
- Create AWS clients inside handler functions
- Use `panic()` for error handling
- Log sensitive data (API keys, tokens, passwords)
- Use CGO unless absolutely necessary
- Deploy x86_64 when ARM64 is available

### Performance Checklist

- [ ] Using ARM64 (Graviton2) architecture
- [ ] AWS clients initialized in `init()`
- [ ] Binary stripped with `-ldflags="-s -w"`
- [ ] Memory configured based on workload (use Power Tuning)
- [ ] Timeout set appropriately (not too long)
- [ ] Concurrent operations use goroutines
- [ ] Database connections pooled

### Security Checklist

- [ ] Secrets from Secrets Manager, not environment variables
- [ ] IAM role with least-privilege permissions
- [ ] Input validation on all external data
- [ ] No sensitive data in logs
- [ ] Error messages don't leak internal details
- [ ] Dependencies scanned for vulnerabilities
