# Nova Act Skill for Claude

This skill enables Claude to generate production-ready Amazon Nova Act Python scripts for browser automation.

## What's Included

### Core Skill Document
- **SKILL.md** - Comprehensive Nova Act skill documentation covering:
  - Nova Act fundamentals and philosophy
  - Complete API reference
  - Best practices and patterns
  - Common use cases and examples
  - Error handling strategies
  - Advanced features

### Example Scripts

Three complete, production-ready examples demonstrating different Nova Act use cases:

#### 1. Price Comparison (`01_price_comparison.py`)
**Use Case**: E-commerce product research and price comparison

**Features**:
- Parallel web scraping across multiple retailers (Amazon, Best Buy, Target)
- Structured data extraction with Pydantic schemas
- Price comparison and savings calculation
- JSON export of results
- Concurrent execution with ThreadPoolExecutor

**Key Learnings**:
- Breaking down complex tasks into smaller act() calls
- Using Pydantic schemas for reliable data extraction
- Parallel browser sessions for speed
- Error handling with try/except

#### 2. Form Filling (`02_form_filling.py`)
**Use Case**: Automated job application submission

**Features**:
- Persistent authentication with saved browser sessions
- Multi-step form navigation
- Captcha detection and human intervention
- File upload handling
- Pre-submission review and confirmation
- Screenshot capture for verification

**Key Learnings**:
- Setting up and reusing authenticated sessions
- Handling captchas with user intervention
- Using BOOL_SCHEMA for yes/no questions
- File upload with Playwright integration
- Taking screenshots for audit trails

#### 3. Monitoring & Alerts (`03_monitoring_alerts.py`)
**Use Case**: Website monitoring and change detection

**Features**:
- Scheduled monitoring with configurable intervals
- Change detection (price, stock status, content)
- Alert system for significant changes
- Historical data tracking
- Summary report generation
- Single-check and scheduled modes

**Key Learnings**:
- Headless browser automation
- State comparison across runs
- Persistent data storage
- Scheduled task execution
- Building reusable monitoring classes

## How to Use This Skill

### For Claude Users

When you want Claude to generate a Nova Act script:

1. **Reference the skill**: "Using the Nova Act skill, create a script that..."
2. **Describe your use case**: Be specific about what you want to automate
3. **Specify requirements**: Mention any special needs (authentication, file handling, etc.)

**Example prompts**:
- "Using the Nova Act skill, create a script that searches for laptops on Amazon and exports the top 10 results with prices to CSV"
- "Build a Nova Act script that fills out contact forms on multiple websites with my information"
- "Create a monitoring script that checks if concert tickets are available and alerts me"

### For Developers

1. **Install Nova Act SDK**:
   ```bash
   pip install nova-act
   ```

2. **Get API Key**:
   - Visit https://nova.amazon.com/act
   - Generate your API key
   - Set environment variable:
     ```bash
     export NOVA_ACT_API_KEY="your_api_key"
     ```

3. **Install Chrome** (optional but recommended):
   ```bash
   playwright install chrome
   ```

4. **Run Example Scripts**:
   ```bash
   # Price comparison
   python examples/01_price_comparison.py
   
   # Form filling (interactive)
   python examples/02_form_filling.py
   
   # Monitoring
   python examples/03_monitoring_alerts.py
   ```

## Skill Structure

The skill is organized around:

### Core Concepts
1. **Atomic Commands**: Break tasks into small, reliable `act()` calls
2. **Structured Extraction**: Use Pydantic schemas for data extraction
3. **Error Handling**: Proper exception catching and retry logic
4. **State Management**: Authentication and browser session persistence
5. **Parallel Execution**: Multiple browser sessions for speed

### Script Patterns

#### Basic Pattern
```python
from nova_act import NovaAct

with NovaAct(starting_page="https://example.com") as nova:
    nova.act("specific action to perform")
    nova.act("another specific action")
```

#### Data Extraction Pattern
```python
from pydantic import BaseModel
from nova_act import NovaAct

class MyData(BaseModel):
    field1: str
    field2: int

with NovaAct(starting_page="https://example.com") as nova:
    result = nova.act(
        "Extract data from the page",
        schema=MyData.model_json_schema()
    )
    if result.matches_schema:
        data = MyData.model_validate(result.parsed_response)
```

#### Authentication Pattern
```python
from nova_act import NovaAct
import os

user_data_dir = "/tmp/browser-profile"
os.makedirs(user_data_dir, exist_ok=True)

# First run: Login
with NovaAct(
    starting_page="https://example.com",
    user_data_dir=user_data_dir,
    clone_user_data_dir=False
) as nova:
    # User logs in manually
    input("Log in, then press Enter...")

# Subsequent runs: Already logged in
with NovaAct(
    starting_page="https://example.com",
    user_data_dir=user_data_dir,
    clone_user_data_dir=True
) as nova:
    nova.act("Navigate to dashboard")
```

#### Parallel Execution Pattern
```python
from concurrent.futures import ThreadPoolExecutor
from nova_act import NovaAct

def process_item(item):
    with NovaAct(starting_page=item['url'], headless=True) as nova:
        return nova.act("Extract data")

items = [{'url': 'https://example.com/1'}, ...]

with ThreadPoolExecutor(max_workers=5) as executor:
    results = list(executor.map(process_item, items))
```

## Best Practices

### 1. Prompting
- ✅ **DO**: Be specific and prescriptive
- ✅ **DO**: Break tasks into multiple small steps
- ❌ **DON'T**: Use vague or conversational prompts
- ❌ **DON'T**: Try to do everything in one act() call

### 2. Data Extraction
- ✅ **DO**: Always use Pydantic schemas for structured data
- ✅ **DO**: Use BOOL_SCHEMA for yes/no questions
- ✅ **DO**: Check `result.matches_schema` before parsing
- ❌ **DON'T**: Parse text responses manually

### 3. Reliability
- ✅ **DO**: Use `go_to_url()` instead of `page.goto()`
- ✅ **DO**: Add error handling with try/except
- ✅ **DO**: Handle captchas with user intervention
- ✅ **DO**: Test scripts in non-headless mode first

### 4. Security
- ✅ **DO**: Use Playwright directly for passwords
- ✅ **DO**: Use getpass() for sensitive input
- ❌ **DON'T**: Put passwords in act() prompts
- ❌ **DON'T**: Display sensitive data on screen during screenshots

### 5. Production
- ✅ **DO**: Use headless=True for production
- ✅ **DO**: Set up proper logging directories
- ✅ **DO**: Clone user_data_dir for parallel sessions
- ✅ **DO**: Implement monitoring and alerting

## Common Use Cases

The skill covers these primary use cases:

1. **E-commerce Automation**
   - Price monitoring
   - Product comparison
   - Cart management
   - Order tracking

2. **Form Filling**
   - Job applications
   - Survey completion
   - Data entry
   - Account creation

3. **Web Scraping**
   - Data extraction
   - Content monitoring
   - Research automation
   - Competitive analysis

4. **Testing & QA**
   - Automated testing
   - User flow validation
   - Regression testing
   - Cross-browser testing

5. **Monitoring**
   - Website availability
   - Content changes
   - Price tracking
   - Inventory monitoring

## Limitations

- **US availability only**
- **English language only**
- **Cannot interact with non-browser applications**
- **Not optimized for PDF actuation**
- **Unreliable with very high-level prompts**
- **No iPython support**
- **Screen size constraints**: 864×1296 to 1536×2304

## Resources

- **Official Repo**: https://github.com/aws/nova-act
- **Documentation**: https://nova.amazon.com/act
- **Blog**: https://labs.amazon.science/blog/nova-act
- **IDE Extension**: https://github.com/aws/nova-act-extension
- **Support**: nova-act@amazon.com

## Skill Maintenance

This skill is based on Nova Act research preview. As Nova Act evolves:
- API changes may require skill updates
- New features should be added to the skill
- Best practices may change based on community feedback
- Examples should be expanded for new use cases

## Contributing

To improve this skill:
1. Add new example scripts for different use cases
2. Document new patterns and best practices
3. Update API reference as Nova Act evolves
4. Add troubleshooting guides for common issues

## License

This skill documentation and examples are provided as-is for educational purposes. Nova Act itself is subject to Amazon's licensing and acceptable use policies.

---

**Last Updated**: November 2025  
**Nova Act Version**: Research Preview  
**Skill Version**: 1.0
