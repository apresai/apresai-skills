# Nova Act Configuration Template

"""
Copy this template to create configuration files for your Nova Act projects.
Save as 'config.py' or similar and customize for your needs.
"""

import os
from typing import Optional, Dict, List
from pydantic import BaseModel


# =============================================================================
# ENVIRONMENT CONFIGURATION
# =============================================================================

class EnvironmentConfig(BaseModel):
    """Environment-specific configuration"""
    
    # Nova Act API Key (required)
    # Set via environment variable: export NOVA_ACT_API_KEY="your_key"
    nova_act_api_key: str = os.getenv("NOVA_ACT_API_KEY", "")
    
    # Environment name
    environment: str = os.getenv("ENVIRONMENT", "development")
    
    # Debug mode
    debug: bool = os.getenv("DEBUG", "false").lower() == "true"


# =============================================================================
# BROWSER CONFIGURATION
# =============================================================================

class BrowserConfig(BaseModel):
    """Browser behavior configuration"""
    
    # Run browser in headless mode (no UI)
    # Set to True for production, False for development/debugging
    headless: bool = True
    
    # Suppress console logs
    quiet: bool = False
    
    # User data directory for persistent sessions
    # Set to None to use temporary directory
    user_data_dir: Optional[str] = None
    
    # Clone user data directory for safety
    # Set to False when setting up authentication
    # Set to True for parallel execution
    clone_user_data_dir: bool = True
    
    # Directory for logs and traces
    logs_directory: str = "./logs"
    
    # Record video of browser session
    record_video: bool = False
    
    # Custom user agent (optional)
    user_agent: Optional[str] = None
    
    # Timeout for page loads (seconds)
    go_to_url_timeout: int = 30


# =============================================================================
# PROXY CONFIGURATION
# =============================================================================

class ProxyConfig(BaseModel):
    """Proxy server configuration"""
    
    # Enable proxy
    enabled: bool = False
    
    # Proxy server URL (e.g., "http://proxy.example.com:8080")
    server: str = ""
    
    # Proxy authentication (optional)
    username: Optional[str] = None
    password: Optional[str] = None
    
    def to_dict(self) -> Optional[Dict[str, str]]:
        """Convert to dict format for NovaAct"""
        if not self.enabled or not self.server:
            return None
        
        proxy_dict = {"server": self.server}
        if self.username:
            proxy_dict["username"] = self.username
        if self.password:
            proxy_dict["password"] = self.password
        
        return proxy_dict


# =============================================================================
# ACT CONFIGURATION
# =============================================================================

class ActConfig(BaseModel):
    """Configuration for act() method calls"""
    
    # Maximum steps before timeout
    max_steps: int = 30
    
    # Timeout in seconds (optional - prefer max_steps)
    timeout: Optional[int] = None
    
    # Delay before taking observations (milliseconds)
    observation_delay_ms: Optional[int] = None


# =============================================================================
# APPLICATION CONFIGURATION
# =============================================================================

class MonitoringConfig(BaseModel):
    """Configuration for monitoring/scraping applications"""
    
    # URLs to monitor
    target_urls: List[str] = []
    
    # Check interval (minutes)
    check_interval_minutes: int = 60
    
    # Maximum number of checks
    max_checks: int = 24
    
    # Send alerts on changes
    enable_alerts: bool = True
    
    # Alert thresholds
    price_change_threshold: float = 5.0  # Dollar amount
    stock_status_alerts: bool = True


class ScrapingConfig(BaseModel):
    """Configuration for web scraping applications"""
    
    # Maximum concurrent sessions
    max_workers: int = 5
    
    # Retry failed requests
    retry_on_error: bool = True
    max_retries: int = 3
    
    # Rate limiting
    delay_between_requests: float = 1.0  # Seconds
    
    # Output format
    output_format: str = "json"  # "json", "csv", "xlsx"
    output_directory: str = "./output"


class AuthenticationConfig(BaseModel):
    """Configuration for authenticated sessions"""
    
    # Path to stored authentication
    auth_data_dir: str = "./auth_profiles"
    
    # Session persistence
    save_sessions: bool = True
    session_name: str = "default"
    
    # Re-authentication
    auto_reauth: bool = False
    reauth_on_error: bool = True


# =============================================================================
# NOTIFICATION CONFIGURATION
# =============================================================================

class NotificationConfig(BaseModel):
    """Configuration for alerts and notifications"""
    
    # Email notifications (requires AWS SES)
    email_enabled: bool = False
    email_from: str = ""
    email_to: List[str] = []
    
    # SMS notifications (requires AWS SNS)
    sms_enabled: bool = False
    sms_phone_numbers: List[str] = []
    
    # Slack notifications
    slack_enabled: bool = False
    slack_webhook_url: str = ""
    
    # Discord notifications
    discord_enabled: bool = False
    discord_webhook_url: str = ""


# =============================================================================
# LOGGING CONFIGURATION
# =============================================================================

class LoggingConfig(BaseModel):
    """Logging configuration"""
    
    # Log level (10=DEBUG, 20=INFO, 30=WARNING, 40=ERROR)
    level: int = 20
    
    # Log to file
    log_to_file: bool = True
    log_file_path: str = "./logs/application.log"
    
    # Log rotation
    max_log_size_mb: int = 10
    backup_count: int = 5
    
    # Include timestamps
    include_timestamps: bool = True


# =============================================================================
# AWS INTEGRATION CONFIGURATION
# =============================================================================

class AWSConfig(BaseModel):
    """AWS integration configuration"""
    
    # AWS region
    region: str = "us-east-1"
    
    # S3 storage for logs/traces
    s3_enabled: bool = False
    s3_bucket_name: str = ""
    s3_prefix: str = "nova-act-logs/"
    
    # CloudWatch logging
    cloudwatch_enabled: bool = False
    cloudwatch_log_group: str = "/nova-act/application"
    
    # Lambda execution
    lambda_enabled: bool = False
    lambda_function_name: str = ""


# =============================================================================
# MAIN CONFIGURATION CLASS
# =============================================================================

class NovaActConfig:
    """Main configuration class combining all settings"""
    
    def __init__(self):
        self.environment = EnvironmentConfig()
        self.browser = BrowserConfig()
        self.proxy = ProxyConfig()
        self.act = ActConfig()
        self.monitoring = MonitoringConfig()
        self.scraping = ScrapingConfig()
        self.authentication = AuthenticationConfig()
        self.notifications = NotificationConfig()
        self.logging = LoggingConfig()
        self.aws = AWSConfig()
    
    def get_nova_act_kwargs(self) -> Dict:
        """Get kwargs dictionary for NovaAct initialization"""
        kwargs = {
            "headless": self.browser.headless,
            "quiet": self.browser.quiet,
            "logs_directory": self.browser.logs_directory,
            "record_video": self.browser.record_video,
            "go_to_url_timeout": self.browser.go_to_url_timeout,
        }
        
        if self.browser.user_data_dir:
            kwargs["user_data_dir"] = self.browser.user_data_dir
            kwargs["clone_user_data_dir"] = self.browser.clone_user_data_dir
        
        if self.browser.user_agent:
            kwargs["user_agent"] = self.browser.user_agent
        
        if self.proxy.enabled:
            proxy_dict = self.proxy.to_dict()
            if proxy_dict:
                kwargs["proxy"] = proxy_dict
        
        if self.environment.nova_act_api_key:
            kwargs["nova_act_api_key"] = self.environment.nova_act_api_key
        
        return kwargs
    
    def get_act_kwargs(self) -> Dict:
        """Get kwargs dictionary for act() method"""
        kwargs = {
            "max_steps": self.act.max_steps,
        }
        
        if self.act.timeout:
            kwargs["timeout"] = self.act.timeout
        
        if self.act.observation_delay_ms:
            kwargs["observation_delay_ms"] = self.act.observation_delay_ms
        
        return kwargs


# =============================================================================
# CONFIGURATION PRESETS
# =============================================================================

def get_development_config() -> NovaActConfig:
    """Configuration for development/debugging"""
    config = NovaActConfig()
    config.browser.headless = False
    config.browser.record_video = True
    config.logging.level = 10  # DEBUG
    return config


def get_production_config() -> NovaActConfig:
    """Configuration for production deployment"""
    config = NovaActConfig()
    config.browser.headless = True
    config.browser.record_video = False
    config.logging.level = 20  # INFO
    config.aws.s3_enabled = True
    return config


def get_testing_config() -> NovaActConfig:
    """Configuration for testing/CI"""
    config = NovaActConfig()
    config.browser.headless = True
    config.browser.record_video = False
    config.logging.level = 30  # WARNING
    return config


# =============================================================================
# EXAMPLE USAGE
# =============================================================================

if __name__ == "__main__":
    """
    Example of how to use this configuration
    """
    
    # Create config for your environment
    config = get_development_config()
    
    # Customize as needed
    config.monitoring.target_urls = [
        "https://www.example.com/product1",
        "https://www.example.com/product2"
    ]
    config.monitoring.check_interval_minutes = 30
    config.notifications.email_enabled = True
    config.notifications.email_to = ["your-email@example.com"]
    
    # Use with NovaAct
    from nova_act import NovaAct
    
    nova_kwargs = config.get_nova_act_kwargs()
    act_kwargs = config.get_act_kwargs()
    
    with NovaAct(starting_page="https://example.com", **nova_kwargs) as nova:
        result = nova.act("perform action", **act_kwargs)
    
    # Access configuration values
    print(f"Environment: {config.environment.environment}")
    print(f"Headless mode: {config.browser.headless}")
    print(f"Log level: {config.logging.level}")
