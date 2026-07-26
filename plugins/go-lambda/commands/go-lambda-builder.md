---
name: go-lambda-builder
description: Generate production-ready Go Lambda functions with provided.al2023 runtime, ARM64 architecture, AWS SDK v2 integration, and CDK infrastructure. Use when building new Lambda functions in Go or migrating from go1.x runtime.
---

# Go Lambda Builder - Complete Reference

## Overview

This skill generates production-ready Go Lambda functions optimized for:
- **Runtime**: `provided.al2023` (required for new functions; `provided.al2` is deprecated July 31, 2026; do not use)
- **Architecture**: ARM64 for up to 20% cheaper, often faster (standard Lambda ARM64 is backed by Graviton2; Graviton4 is available only via Lambda Managed Instances)
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
	"log"
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
)

func init() {
	// Use lambda.NewLogHandler() (aws-lambda-go v1.54+): reads AWS_LAMBDA_LOG_FORMAT /
	// AWS_LAMBDA_LOG_LEVEL and auto-injects requestId. Falls back to slog.NewJSONHandler
	// on older versions of the library.
	slog.SetDefault(slog.New(lambda.NewLogHandler()))

	// Load AWS config: use log.Fatal so failures emit a clean runtime init error
	// in CloudWatch rather than an unhandled panic.
	cfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		log.Fatalf("failed to load AWS config: %v", err)
	}

	// Initialize clients (reused across invocations)
	dbClient = dynamodb.NewFromConfig(cfg)
	tableName = os.Getenv("TABLE_NAME")
}

func handler(ctx context.Context, event events.APIGatewayProxyRequest) (events.APIGatewayProxyResponse, error) {
	slog.Info("processing request",
		"path", event.Path,
		"method", event.HTTPMethod,
		// requestId injected automatically by lambda.NewLogHandler
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

// Context, input, output (RECOMMENDED for compatibility)
func (context.Context, TIn) (TOut, error)
```

### Generic Handler (aws-lambda-go v1.47+, RECOMMENDED for new code)

`StartHandlerFunc` provides compile-time type safety via Go generics. Prefer it for new functions:

```go
import "github.com/aws/aws-lambda-go/lambda"

type Request struct {
	UserID string `json:"userId"`
}

type Response struct {
	Message string `json:"message"`
}

func handler(ctx context.Context, req Request) (Response, error) {
	return Response{Message: "ok"}, nil
}

func main() {
	// Type parameters are inferred from the handler signature.
	lambda.StartHandlerFunc(handler)
}
```

### Graceful Shutdown with WithEnableSIGTERM (aws-lambda-go v1.41+)

Stateful Lambdas (connection pools, buffered writers) should flush on SIGTERM. Lambda sends SIGTERM ~500 ms before the hard kill during scale-in:

```go
func main() {
	lambda.StartWithOptions(handler,
		lambda.WithEnableSIGTERM(func() {
			// Flush logs, drain pools, close DB connections
			slog.Info("SIGTERM received, shutting down")
		}),
	)
}
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

		// TenantID is populated when Lambda Tenant Isolation Mode is active (aws-lambda-go v1.54+).
		// Empty string means the function is not running in a tenant-isolated context.
		if lc.TenantID != "" {
			slog.Info("tenant context", "tenantId", lc.TenantID)
		}
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

// Upload large file with Transfer Manager v2 (GA January 2026)
// manager.NewUploader / manager.NewDownloader are still available as the manager package API;
// the Transfer Manager v2 unifies upload and download under a single client with improved
// defaults. Use the manager package for multipart uploads in Lambda.
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

**Preferred: `lambda.NewLogHandler()` (aws-lambda-go v1.54+)**

`lambda.NewLogHandler()` reads `AWS_LAMBDA_LOG_FORMAT` and `AWS_LAMBDA_LOG_LEVEL` set by the Lambda console or CDK, and auto-injects `requestId` into every log line (no manual wiring required):

```go
import (
	"log/slog"
	"github.com/aws/aws-lambda-go/lambda"
)

func init() {
	// Reads AWS_LAMBDA_LOG_FORMAT (JSON/TEXT) and AWS_LAMBDA_LOG_LEVEL automatically.
	// Sets slog.Default so package-level slog.Info/Error calls work without a logger var.
	slog.SetDefault(slog.New(lambda.NewLogHandler()))
}

func handler(ctx context.Context, event events.APIGatewayProxyRequest) (events.APIGatewayProxyResponse, error) {
	slog.Info("processing request",
		"path", event.Path,
		"method", event.HTTPMethod,
	)
	// requestId is injected automatically from the Lambda context.
	return events.APIGatewayProxyResponse{StatusCode: 200}, nil
}
```

**Fallback: manual slog setup (aws-lambda-go < v1.54 or custom formatting)**

Use this only when `lambda.NewLogHandler()` is unavailable or you need non-standard log routing:

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

### Why not SnapStart?

SnapStart (snapshot-based cold start elimination) is supported for Java 11+, Python 3.12+, and .NET 8+ only. **Go is not supported and there is no announced roadmap.** For Go, use connection pooling in `init()` and Provisioned Concurrency when sub-100 ms cold start is required.

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
		// Use log.Fatal so the failure surfaces as a runtime init error in CloudWatch,
		// not as an unhandled panic. Avoid panic() in init().
		log.Fatalf("failed to load AWS config: %v", err)
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

---

## Production Patterns (mined from real projects)

The sections below document patterns extracted from ~12 production Lambda projects. Where the pattern originates from a specific project it's noted explicitly. Use that as a reference when you need the full context.

---

### Lambda init Pattern (Cold-Start Friendly)

Global vars are initialized once at cold start and reused across all invocations in that container's lifetime. Fail fast with `os.Exit(1)` or `log.Fatalf` so a bad environment surfaces as a clean runtime init error in CloudWatch rather than a misleading panic or a handler invocation that silently does nothing.

The pattern from **emailz** (`cmd/email-forwarder/main.go`). Note the bounded timeout on `LoadDefaultConfig` to prevent a hung IMDS call from pinning the cold start indefinitely:

```go
var (
    s3Bucket      string
    forwardToAddr string
    forwarder     *email.Forwarder
)

func init() {
    s3Bucket = os.Getenv("S3_BUCKET")
    forwardToAddr = os.Getenv("FORWARD_TO_EMAIL")
    if s3Bucket == "" || forwardToAddr == "" {
        log.Fatal("Missing required env vars: S3_BUCKET, FORWARD_TO_EMAIL")
    }

    // Bounded timeout prevents hung IMDS/STS calls from pinning cold start.
    ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
    defer cancel()

    cfg, err := config.LoadDefaultConfig(ctx)
    if err != nil {
        log.Fatalf("Failed to load AWS config: %v", err)
    }

    forwarder = email.NewForwarder(s3.NewFromConfig(cfg), ses.NewFromConfig(cfg), ...)
}
```

The pattern from **regist** (`cmd/api-auth/main.go`) logs a cold-start marker so you can measure container reuse in CloudWatch:

```go
func init() {
    slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{
        Level: slog.LevelInfo,
    })))
    slog.Info("lambda_cold_start", "function", "api-auth")

    tableName := os.Getenv("TABLE_NAME")
    dbClient, err = db.New(ctx, tableName)
    if err != nil {
        slog.Error("failed to create db client", "error", err)
        os.Exit(1)
    }
    // ... more clients ...
}
```

The pattern from **eleven9s** (`backend/cmd/api/main.go`) chains dependency construction through a `config.Load` helper and uses `os.Exit(1)` after each failure so the full init always runs and every bad config field is visible in one cold-start log:

```go
func init() {
    slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
        Level: slog.LevelInfo,
    })))

    ctx := context.Background()
    cfg, err := config.Load(ctx)
    if err != nil {
        slog.Error("load config", "err", err)
        os.Exit(1)
    }

    db, err := ddb.New(ctx, cfg.Region, cfg.TableName)
    if err != nil {
        slog.Error("ddb client", "err", err)
        os.Exit(1)
    }

    // ... more dependencies wired via cfg ...

    lambdaAdapter = httpadapter.NewV2(authed)
}
```

**Rules:**
- Load all env vars at the top of `init()` and fail immediately if required ones are missing.
- Use `os.Exit(1)` (with `slog.Error`) or `log.Fatalf`. Never `panic()`.
- Wrap `config.LoadDefaultConfig` with a `context.WithTimeout` (10 s is enough).
- Assign AWS clients to package-level vars so the handler function never calls `NewFromConfig`.

---

### DynamoDB Single-Table with Typed Go Structs

Every project uses `PK`/`SK` compound keys with entity-type prefixes and `dynamodbav` struct tags. **Never use `map[string]interface{}`**: DynamoDB's attribute marshaller corrupts ULIDs and RFC3339 timestamps when they go through `interface{}` round-trips.

**Entity prefix inventory across projects:**

| Project | Entity prefixes |
|---------|----------------|
| eleven9s | `USER#`, `MEDIA#`, `ALBUM#`, `CLUSTER#`, `APPLE_TX#`, `STATUS#uploading` |
| for-the-win | `USER#`, `GROUP#`, `LEADERBOARD#` |
| regist | `USER#`, `REFRESH#`, `HASH#`, `MEETING#`, `CONTACT#` |
| sophie | `WINE#`, `UPLOAD#`, `REVIEW#`, `ENRICHMENT#`, `AI_CALL#`, `ENTITY#` |
| emailz | N/A: no DDB (SES → S3 only) |

**Standard struct shape** (from sophie's `internal/db/dynamodb.go`):

```go
// WineItem is the DDB representation of a Wine entity.
// PK and SK are the only fields read by GetItem/Query key conditions.
// All other fields use dynamodbav so marshal/unmarshal is automatic.
type WineItem struct {
    PK string `dynamodbav:"PK"` // WINE#{wineId}
    SK string `dynamodbav:"SK"` // METADATA

    // Embed the domain model: avoids duplicating every field.
    Data models.Wine `dynamodbav:"Data"`

    // GSI keys (omitempty so sparse indexing works correctly)
    GSI1PK string `dynamodbav:"GSI1PK,omitempty"` // TYPE#{wineType}
    GSI1SK string `dynamodbav:"GSI1SK,omitempty"` // REGION#{region}
    GSI5PK string `dynamodbav:"GSI5PK,omitempty"` // SLUG#{slug}
    GSI5SK string `dynamodbav:"GSI5SK,omitempty"` // METADATA
}
```

**Key construction helpers** (from for-the-win's `internal/db/`):

```go
// Key helpers: small functions prevent typos in ad-hoc string concat.
func userPK(userID string) string            { return "USER#" + userID }
func groupPK(groupID string) string          { return "GROUP#" + groupID }
func leaderboardSK(period, date string) string {
    return "LEADERBOARD#" + period + "#" + date
}
```

**Shared DB client wrapper** (from for-the-win and eleven9s, identical pattern):

```go
// internal/db/client.go
type Client struct {
    DDB       *dynamodb.Client
    TableName string
}

func New(ctx context.Context, tableName string) (*Client, error) {
    cfg, err := config.LoadDefaultConfig(ctx)
    if err != nil {
        return nil, fmt.Errorf("load aws config: %w", err)
    }
    return &Client{
        DDB:       dynamodb.NewFromConfig(cfg),
        TableName: tableName,
    }, nil
}
```

**GSI naming convention**: GSI1 through GSI5 (and beyond) named `GSI1-Purpose` in CDK, referenced as `"GSI1"` in query code. regist uses `GSI1-UserDate`, `GSI2-TokenHash`. eleven9s documents purpose in `docs/ddb-schema.yaml`.

---

### ULID for Sortable IDs

All projects use `github.com/oklog/ulid/v2` instead of `google/uuid`. ULIDs are 26-char Crockford base32, lexicographically sortable by creation time, and safe for DynamoDB sort keys. eleven9s wraps this in an `internal/ids` package:

```go
// internal/ids/ulid.go
package ids

import (
    "crypto/rand"
    "time"

    "github.com/oklog/ulid/v2"
)

// New returns a freshly generated ULID string (26 chars, Crockford base32).
// ULIDs sort lexicographically and encode a timestamp, preferred over UUID v4.
func New() string {
    return ulid.MustNew(ulid.Timestamp(time.Now()), rand.Reader).String()
}

// ParseTime extracts the timestamp embedded in a ULID string.
func ParseTime(s string) (time.Time, error) {
    u, err := ulid.Parse(s)
    if err != nil {
        return time.Time{}, fmt.Errorf("parse ulid %q: %w", s, err)
    }
    return ulid.Time(u.Time()), nil
}
```

Regist and for-the-win call `ulid.MustNew(ulid.Timestamp(time.Now()), rand.Reader).String()` inline. Prefer the wrapper package pattern for projects with multiple Lambdas so the generation logic lives in one place.

---

### OpenAPI-First Workflow (Go Side)

**eleven9s** is the canonical reference for the full oapi-codegen pipeline. The config (`backend/oapi-codegen-public.yaml`) generates types, an `std-http-server`, and a `strict-server` simultaneously:

```yaml
# backend/oapi-codegen-public.yaml
output: internal/api/api.gen.go
package: api
generate:
  models: true
  std-http-server: true     # net/http mux wiring, no framework
  strict-server: true       # typed request/response wrappers
  embedded-spec: false
```

```makefile
# backend/Makefile
gen-public:
    oapi-codegen -config oapi-codegen-public.yaml ../openapi/public-api.yaml

gen-admin:
    oapi-codegen -config oapi-codegen-admin.yaml ../openapi/admin-api.yaml
```

The generated `api.gen.go` produces a `StrictServerInterface` that your implementation struct satisfies. The `main.go` wires it through `httpadapter` for API Gateway HTTP API v2:

```go
// cmd/api/main.go (eleven9s pattern)
var lambdaAdapter *httpadapter.HandlerAdapterV2

func init() {
    // ... build all deps ...
    server := api.NewServer(cfg, db, ...)
    strictHandler := api.NewStrictHandlerWithOptions(server, nil, api.StrictHTTPServerOptions{
        RequestErrorHandlerFunc: func(w http.ResponseWriter, r *http.Request, err error) {
            slog.WarnContext(r.Context(), "strict request error", "err", err)
            writeErrorEnvelope(w, http.StatusBadRequest, "bad_request", "Bad request")
        },
        ResponseErrorHandlerFunc: func(w http.ResponseWriter, r *http.Request, err error) {
            slog.ErrorContext(r.Context(), "strict response error", "err", err)
            writeErrorEnvelope(w, http.StatusInternalServerError, "internal_error", "Internal error")
        },
    })
    mux := http.NewServeMux()
    routed := api.HandlerFromMux(strictHandler, mux)
    authed := api.AuthMiddleware(jwtIssuer)(routed)
    lambdaAdapter = httpadapter.NewV2(authed)
}

func handler(ctx context.Context, req events.APIGatewayV2HTTPRequest) (events.APIGatewayV2HTTPResponse, error) {
    return lambdaAdapter.ProxyWithContext(ctx, req)
}
```

The `httpadapter` package is `github.com/awslabs/aws-lambda-go-api-proxy/httpadapter`.

**Route parity test**: for-the-win's `TestRoutesMatchSpec` (`packages/api/internal/handlers/routes_test.go`) parses the Go 1.22+ `mux.HandleFunc` call strings with `go/ast` and compares them to `api.yaml` paths loaded via `github.com/getkin/kin-openapi/openapi3`. Any route in code but not in spec (or vice versa) fails the test. Run it with:

```bash
make test-api-spec
# expands to: go test ./internal/handlers/ -run TestRoutesMatchSpec -v
```

The spec also drives Swift client generation (`gen-swift-client`) and TypeScript types (`gen-go-types`) from the same YAML: one spec, four generated artifacts.

---

### Structured Logging (slog)

The existing skill covers `lambda.NewLogHandler()` (v1.54+) and the manual fallback. The real projects add two patterns:

**1. Error codes for searchable log correlation** (from regist's `shared/logging/logging.go`):

```go
// shared/logging/logging.go
const (
    RGAuth001 = "RG-AUTH-001" // Invalid token
    RGAuth003 = "RG-AUTH-003" // Refresh token reuse detected
    RGAuth005 = "RG-AUTH-005" // STS assume role failed
    RGDB001   = "RG-DB-001"   // DynamoDB operation failed
    RGSumm001 = "RG-SUMM-001" // Bedrock invocation failed
)

func Error(ctx context.Context, code, msg string, args ...any) {
    allArgs := append([]any{"error_code", code}, args...)
    logger.ErrorContext(ctx, msg, allArgs...)
}
```

Usage: `logging.Error(ctx, logging.RGDB001, "token lookup failed", "error", err)`. The `error_code` field lets CloudWatch Insights group errors by type independently of the message string.

**2. Structured phase logging for multi-step Lambdas** (from sophie's `generate-article`):

```go
// Log each pipeline phase with a consistent field set so queries can
// filter by phase= or measure latency across invocations.
fmt.Printf("INFO: [generate-article] phase=generate_start requestId=%s topic=\"%s\"\n",
    event.RequestID, req.Topic)
// ... do work ...
fmt.Printf("INFO: [generate-article] phase=generate_complete requestId=%s durationMs=%d\n",
    event.RequestID, generateDuration.Milliseconds())
```

Sophie uses `fmt.Printf` with key=value pairs for structured logs without a logger dependency (the generate-article Lambda predates slog adoption in that project). New code should use `slog.InfoContext(ctx, "phase", "phase", "generate_complete", "requestId", ..., "durationMs", ...)`.

---

### Event-Driven Lambda Patterns

**EventBridge consumer** (from for-the-win's `score-compute`):

```go
lambda.Start(func(ctx context.Context, event json.RawMessage) error {
    // Attempt to parse as an EventBridge envelope first.
    var ebEvent struct {
        DetailType string          `json:"detail-type"`
        Detail     json.RawMessage `json:"detail"`
    }
    if err := json.Unmarshal(event, &ebEvent); err == nil && ebEvent.Detail != nil {
        var detail struct {
            UserID string `json:"userId"`
        }
        if err := json.Unmarshal(ebEvent.Detail, &detail); err == nil && detail.UserID != "" {
            switch ebEvent.DetailType {
            case "StepsUpdated", "BadgeEarned":
                return recomputeUserScore(ctx, dbClient, detail.UserID)
            }
        }
    }
    // Fall through to full recompute (cron trigger has no detail).
    return recomputeAllRanks(ctx, dbClient)
})
```

**EventBridge publisher** (from sophie's `generate-article`):

```go
func publishArticleCreated(ctx context.Context, article *models.Article) {
    detail := map[string]interface{}{
        "articleId": article.ArticleId,
        "slug":      article.Slug,
        "category":  string(article.Category),
    }
    detailJSON, _ := json.Marshal(detail)
    detailStr := string(detailJSON)
    source := "stcom.content"
    detailType := "Content.ArticleCreated"

    _, err = eventBridgeClient.PutEvents(ctx, &eventbridge.PutEventsInput{
        Entries: []eventbridgetypes.PutEventsRequestEntry{
            {
                Source:       &source,
                DetailType:   &detailType,
                Detail:       &detailStr,
                EventBusName: &eventBusName,
            },
        },
    })
}
```

**EventBridge → SQS → Lambda envelope unwrap** (sophie's `generate-article` handles all three trigger paths: SQS-wrapped EventBridge, direct EventBridge, and direct invocation for tests):

```go
func handler(ctx context.Context, rawEvent json.RawMessage) (*GenerateResult, error) {
    var event ContentRequestCreatedEvent

    // Try SQS wrapper first (EventBridge → SQS → Lambda path)
    var sqsEvent struct {
        Records []struct{ Body string `json:"body"` } `json:"Records"`
    }
    if err := json.Unmarshal(rawEvent, &sqsEvent); err == nil && len(sqsEvent.Records) > 0 {
        var envelope struct{ Detail json.RawMessage `json:"detail"` }
        if err := json.Unmarshal([]byte(sqsEvent.Records[0].Body), &envelope); err != nil {
            // Malformed: drop, don't retry (parse errors are never retryable)
            return &GenerateResult{Error: "malformed SQS body"}, nil
        }
        json.Unmarshal(envelope.Detail, &event)
    } else {
        // Try direct EventBridge, then direct invocation for testing
        var envelope struct{ Detail json.RawMessage `json:"detail"` }
        if err := json.Unmarshal(rawEvent, &envelope); err == nil && envelope.Detail != nil {
            json.Unmarshal(envelope.Detail, &event)
        } else {
            json.Unmarshal(rawEvent, &event)
        }
    }
    // ... handle event ...
}
```

**Scheduled cron** (from models-apresai, runs every 4 hours via CDK EventBridge rule):

```typescript
// infrastructure/lib/models-apresai-stack.ts
new events.Rule(this, 'CollectorSchedule', {
    ruleName: 'models-apresai-collector-cron',
    description: 'Run the collector every 4 hours (00/04/08/12/16/20 UTC)',
    schedule: events.Schedule.expression('cron(0 0,4,8,12,16,20 * * ? *)'),
    targets: [new targets.LambdaFunction(collectorFn)],
});
```

The Go handler for scheduled events receives an `events.CloudWatchEvent` (or `json.RawMessage` if you don't need the event fields).

---

### STS AssumeRole Pattern

Regist's `api-auth` Lambda issues scoped STS credentials so the iOS SDK can call DynamoDB and S3 directly without proxying through the API. This eliminates a per-request Lambda invocation for streaming workloads like Transcribe.

The session policy restricts DDB to `USER#{userID}` leading keys and S3 to `{userID}/*` prefixes. Two scope levels are provided: full (DDB + S3 + Transcribe) and Transcribe-only for web clients.

```go
// assumeRoleForUser issues credentials scoped to a single user's data.
// Policy is built via json.Marshal (not fmt.Sprintf) so userID characters
// cannot break out of the JSON string.
func assumeRoleForUser(ctx context.Context, userID string) (*sts.AssumeRoleOutput, error) {
    if !ulidPattern.MatchString(userID) {
        return nil, fmt.Errorf("invalid userID format")
    }
    tableName := os.Getenv("TABLE_NAME")

    policyDoc := map[string]any{
        "Version": "2012-10-17",
        "Statement": []map[string]any{
            {
                "Effect": "Allow",
                "Action": []string{
                    "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem",
                    "dynamodb:DeleteItem", "dynamodb:Query",
                },
                "Resource": fmt.Sprintf("arn:aws:dynamodb:*:*:table/%s", tableName),
                "Condition": map[string]any{
                    "ForAllValues:StringLike": map[string]any{
                        "dynamodb:LeadingKeys": []string{"USER#" + userID},
                    },
                },
            },
            {
                "Effect": "Allow",
                "Action": []string{"s3:PutObject", "s3:GetObject"},
                "Resource": "arn:aws:s3:::my-bucket-*/" + userID + "/*",
            },
        },
    }
    policyBytes, _ := json.Marshal(policyDoc)
    policy := string(policyBytes)
    sessionName := "myapp-" + userID[:8] // first 8 chars of ULID = timestamp

    return stsClient.AssumeRole(ctx, &sts.AssumeRoleInput{
        RoleArn:         &stsRoleARN,
        RoleSessionName: &sessionName,
        Policy:          &policy,
        DurationSeconds: aws.Int32(3600),
    })
}
```

**When to use this pattern:**
- Mobile/desktop client needs to call AWS services directly (avoids Lambda-as-proxy latency).
- The resource can be scoped by user ID in IAM (`LeadingKeys` for DDB, path prefix for S3).
- You need Transcribe streaming, which cannot be proxied through a Lambda without very large buffers.

**When NOT to use:**
- Resources cannot be scoped per-user (e.g., a shared table where users can't be isolated by leading key).
- The client is web-only and XSS risk of credential exposure is unacceptable (use Transcribe-only scope or proxy instead).

---

### DDB Schema Enforcement (make ddb-lint)

**eleven9s** declares every DynamoDB attribute in `docs/ddb-schema.yaml` and enforces it with `TestSchemaDrift` in `backend/internal/ddb/schema_test.go`. The YAML is the source of truth: edit it first, then update the `*Row` struct, then the handler, all in the same commit.

```makefile
# Root Makefile
ddb-lint:
    cd backend && go test -run TestSchemaDrift -v ./internal/ddb/...
```

`TestSchemaDrift` reflects over every registered `*Row` struct and cross-checks:
1. Every attribute in YAML has a matching `dynamodbav` tag on the struct.
2. Every tagged struct field is declared in YAML.
3. DDB type in YAML (`S`, `N`, `BOOL`) is consistent with the Go type.

```go
// schema_test.go: register every entity you want validated
types := map[string]reflect.Type{
    "User":   reflect.TypeOf(UserRow{}),
    "Media":  reflect.TypeOf(MediaRow{}),
    "Album":  reflect.TypeOf(AlbumRow{}),
    // ... all entities ...
}
sch, _ := loadSchema() // reads docs/ddb-schema.yaml
// checkEntity cross-checks each entity against its reflect.Type
```

Wire this into CI as `make ddb-lint` so a schema change that forgets to update the struct (or vice versa) fails the build before deploy.

---

### Cost Tagging

Every project applies four standard tags to the entire CDK app in `infrastructure/bin/<project>.ts`. This ensures all resources (Lambda, DDB, S3, CloudFront, API Gateway) carry consistent tags for Cost Explorer filtering.

```typescript
// infrastructure/bin/myapp.ts: apply after creating the app, before synth
const app = new cdk.App();
new MyAppStack(app, 'MyAppStack', { env: { account: '...', region: 'us-east-1' } });

cdk.Tags.of(app).add('project',    'my-project-slug'); // lowercase, kebab
cdk.Tags.of(app).add('env',        'prod');
cdk.Tags.of(app).add('managed-by', 'cdk');
cdk.Tags.of(app).add('owner',      'chad');
```

`cdk.Tags.of(app).add(...)` applies the tag to every resource in every stack under the app via a CDK Aspect: no per-resource tagging required. Apply it to the app object, not the stack, so it propagates to nested stacks.

Reference: `obsidian:resources/aws-cost-tagging.md` for the full tagging policy.

---

### Makefile Patterns

All projects follow the same skeleton. Key invariants: `GOOS=linux GOARCH=arm64 CGO_ENABLED=0`, output binary named `bootstrap`, zipped from inside the build directory so the zip root contains `bootstrap` directly.

**Single Lambda (emailz pattern):**

```makefile
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build \
    -tags lambda.norpc \
    -ldflags="-s -w" \
    -o build/bootstrap ./cmd/email-forwarder
cd build && zip -q email-forwarder.zip bootstrap
```

**Multiple Lambdas (eleven9s pattern, parallel-friendly via make's default jobserver):**

```makefile
LAMBDAS := api apple-webhook admin-ops sweep egress-analyzer
BUILD_DIR := build
GOFLAGS := -ldflags="-s -w" -tags lambda.norpc
GOENV := GOOS=linux GOARCH=arm64 CGO_ENABLED=0

build: $(LAMBDAS)

# Pattern rule: each Lambda name expands to this recipe.
$(LAMBDAS):
    @mkdir -p $(BUILD_DIR)/$@
    $(GOENV) go build $(GOFLAGS) -o $(BUILD_DIR)/$@/bootstrap ./cmd/$@
    cd $(BUILD_DIR)/$@ && zip -q ../$@.zip bootstrap
```

Run `make -j4 build` to build four Lambdas in parallel. CDK reads the zip files from `build/*.zip` using `lambda.Code.fromAsset('build/api.zip')`.

**Regist's pattern** adds `-trimpath` to strip build machine paths from the binary (improves reproducibility and shrinks the binary slightly):

```makefile
GOFLAGS := -trimpath
LDFLAGS := -s -w
# ...
$(GOENV) go build $(GOFLAGS) -ldflags "$(LDFLAGS)" -o bin/$@/bootstrap ./cmd/$@
```

**Build a single Lambda by name** (regist's convenience target):

```makefile
build-lambda-%:
    cd $(LAMBDA_DIR) && $(GOENV) go build $(GOFLAGS) \
        -ldflags "$(LDFLAGS)" -o bin/$*/bootstrap ./cmd/$*
```

Usage: `make build-lambda-api-auth`.

**Standard targets every project should have:**

| Target | Description |
|--------|-------------|
| `make build` | Cross-compile all Lambdas to `build/` or `dist/` |
| `make deploy` | `build` + `cd infrastructure && npx cdk deploy` |
| `make clean` | Remove `build/`, `dist/`, `cdk.out/` |
| `make test` | `go test ./...` |
| `make gen` | Re-run oapi-codegen (if OpenAPI-first) |
| `make lint` | `golangci-lint run ./...` |

---

### Powertools-for-Go

**There is no Powertools for Lambda Go package.** The Python/TypeScript/Java Powertools libraries have no Go equivalent: the open feature request is `aws-powertools/powertools-lambda #82`. Do not suggest `aws-lambda-powertools-go` or any similar package name; it does not exist.

Go developers substitute:
- **Tracing**: `github.com/aws/aws-xray-sdk-go` (X-Ray SDK, used in emailz)
- **Logging**: `log/slog` with `lambda.NewLogHandler()` (v1.54+) or `slog.NewJSONHandler`
- **Middleware**: hand-rolled `http.Handler` wrapper or `httpadapter` + `net/http` middleware

---

## Best Practices Summary

### DO

- Use `provided.al2023` runtime with ARM64 architecture
- Initialize AWS clients in `init()` for connection reuse
- Use `context.Context` for all operations
- Wrap errors with `fmt.Errorf("context: %w", err)`
- Use `lambda.NewLogHandler()` for slog setup (aws-lambda-go v1.54+)
- Use `lambda.StartHandlerFunc` for new handlers (compile-time type safety)
- Define small, focused interfaces
- Use table-driven tests
- Build with `-ldflags="-s -w"` for smaller binaries

### DON'T

- Use global `map[string]interface{}` for DynamoDB (causes type corruption)
- Ignore context cancellation
- Create AWS clients inside handler functions
- Use `panic()` in `init()`: prefer `log.Fatal` so failures surface as clean runtime init errors
- Log sensitive data (API keys, tokens, passwords)
- Use CGO unless absolutely necessary
- Deploy x86_64 when ARM64 is available
- Use `provided.al2` for new functions (deprecated July 31, 2026)

### Performance Checklist

- [ ] Using ARM64 architecture (standard Lambda ARM64 = Graviton2; Graviton4 requires Lambda Managed Instances)
- [ ] AWS clients initialized in `init()`
- [ ] Binary stripped with `-ldflags="-s -w"`
- [ ] Memory configured based on workload (use Power Tuning)
- [ ] Timeout set appropriately (not too long)
- [ ] Concurrent operations use goroutines
- [ ] Database connections pooled
- [ ] `WithEnableSIGTERM` registered if the function holds stateful resources

### Platform Compatibility Notes

- **SnapStart**: Java, Python, .NET only. Go is not supported and no roadmap exists. Use Provisioned Concurrency for latency-sensitive Go functions.
- **Powertools for Lambda**: Available for Python, TypeScript, Java, and .NET. There is no Go implementation (open feature request: aws-powertools/powertools-lambda #82). Go developers use `slog` + `aws-xray-sdk-go` + hand-rolled middleware instead.
- **Runtime lifecycle**: `provided.al2023` deprecation is June 30, 2029. `provided.al2` deprecates July 31, 2026. Do not use for new functions.
- **AWS SDK for Go**: v2 is the current and actively maintained SDK. No v3 is announced or planned.
- **CDK**: v2 is the current major. AWS has confirmed there will be no CDKv3.

### Security Checklist

- [ ] Secrets from Secrets Manager, not environment variables
- [ ] IAM role with least-privilege permissions
- [ ] Input validation on all external data
- [ ] No sensitive data in logs
- [ ] Error messages don't leak internal details
- [ ] Dependencies scanned for vulnerabilities
