# Nova Act Quick Start Guide

Get started with Nova Act in 5 minutes!

## Prerequisites Checklist

- [ ] Python 3.10 or higher installed
- [ ] US-based (Nova Act is US-only currently)
- [ ] Amazon.com account (not AWS account)
- [ ] MacOS, Ubuntu 22.04+, WSL2, or Windows 10+

## Step 1: Get Your API Key

1. Visit https://nova.amazon.com/act
2. Sign in with your **Amazon.com** account (the one you shop with, not AWS)
3. Click "Generate API Key"
4. Copy your API key (keep it secret!)

💡 If you're placed on a waitlist, check your email for access notification.

## Step 2: Install Nova Act

```bash
# Install the SDK
pip install nova-act

# Install Chrome (optional but recommended)
playwright install chrome
```

## Step 3: Set Your API Key

```bash
# Set as environment variable
export NOVA_ACT_API_KEY="your_api_key_here"

# Or add to your ~/.bashrc or ~/.zshrc to persist
echo 'export NOVA_ACT_API_KEY="your_api_key_here"' >> ~/.bashrc
source ~/.bashrc
```

## Step 4: Test Your Installation

Create a file called `test_nova.py`:

```python
from nova_act import NovaAct

print("Testing Nova Act installation...")

with NovaAct(starting_page="https://nova.amazon.com/act") as nova:
    result = nova.act("What is the main heading on this page?")
    print(f"\nResult: {result.response}")

print("\n✓ Nova Act is working!")
```

Run it:
```bash
python test_nova.py
```

**First Run Note**: The first time you run Nova Act, it may take 1-2 minutes to install Playwright modules. Subsequent runs will be much faster!

## Step 5: Try a Simple Example

### Example 1: Basic Search

```python
from nova_act import NovaAct

with NovaAct(starting_page="https://www.google.com") as nova:
    nova.act("search for python programming")
    nova.act("click on the first result")
    print(f"Current page: {nova.page.title()}")
```

### Example 2: Extract Data

```python
from nova_act import NovaAct
from pydantic import BaseModel

class WeatherInfo(BaseModel):
    temperature: int
    conditions: str

with NovaAct(starting_page="https://www.weather.gov") as nova:
    nova.act("enter zip code 94102 and search")
    result = nova.act(
        "What is the current temperature and weather conditions?",
        schema=WeatherInfo.model_json_schema()
    )
    
    if result.matches_schema:
        weather = WeatherInfo.model_validate(result.parsed_response)
        print(f"It's {weather.temperature}°F and {weather.conditions}")
```

### Example 3: Check a Condition

```python
from nova_act import NovaAct, BOOL_SCHEMA

with NovaAct(starting_page="https://www.amazon.com") as nova:
    result = nova.act(
        "Are there any deals or promotions shown on the homepage?",
        schema=BOOL_SCHEMA
    )
    
    if result.matches_schema:
        if result.parsed_response:
            print("Deals are available!")
        else:
            print("No deals found.")
```

## Step 6: Explore Examples

Check out the included example scripts:

```bash
# Price comparison across retailers
python examples/01_price_comparison.py

# Automated form filling
python examples/02_form_filling.py

# Website monitoring
python examples/03_monitoring_alerts.py
```

## Common First-Time Issues

### Issue: "API key not found"
**Solution**: Make sure you've set the environment variable:
```bash
export NOVA_ACT_API_KEY="your_key"
```

### Issue: "Chrome not found"
**Solution**: Install Chrome via Playwright:
```bash
playwright install chrome
```

### Issue: "Module not found"
**Solution**: Install Nova Act in your active Python environment:
```bash
pip install nova-act
```

### Issue: First run is very slow
**Expected**: The first run installs Playwright modules (1-2 minutes). Subsequent runs are much faster.

### Issue: "Command not found: playwright"
**Solution**: Make sure you're in the same environment where you installed nova-act:
```bash
which python  # Should show your venv or conda env
pip list | grep nova-act  # Should show installed
```

## Interactive Mode (Great for Learning!)

You can use Nova Act interactively in the Python shell:

```bash
python
```

```python
>>> from nova_act import NovaAct
>>> nova = NovaAct(starting_page="https://www.google.com")
>>> nova.start()
>>> nova.act("search for cats")
>>> nova.act("click on Images")
>>> # Browser stays open - try more commands!
>>> nova.stop()  # When done
```

**Tip**: Use `Ctrl+X` to exit an act() early while keeping the browser open. Use `Ctrl+C` to exit everything.

## Viewing What Nova Act Is Doing

### Non-Headless Mode (See the Browser)
```python
with NovaAct(starting_page="https://example.com", headless=False) as nova:
    # You'll see the browser window
    nova.act("click on the first link")
```

### View Traces After Execution
After each `act()` completes, Nova Act creates an HTML trace file showing:
- Screenshots at each step
- Actions taken
- Reasoning process
- Results

Look for the console output:
```
** View your act run here: /tmp/.../act_xxxxx_output.html
```

Open this file in your browser to see exactly what happened!

### Record Video
```python
with NovaAct(
    starting_page="https://example.com",
    logs_directory="./my_logs",
    record_video=True
) as nova:
    nova.act("perform actions")
# Video saved to ./my_logs/
```

## Next Steps

1. **Read the skill documentation**: See `skills/nova-act-builder/SKILL.md` for comprehensive reference
2. **Study the examples**: Learn patterns from the example scripts
3. **Build something**: Start with a simple use case
4. **Join the community**: Check GitHub issues for tips and solutions

## Key Concepts to Remember

### 1. Break Tasks Into Small Steps
```python
# ❌ Don't do this
nova.act("Find the cheapest laptop under $1000 and add it to cart")

# ✅ Do this instead
nova.act("search for laptops")
nova.act("set price filter to under $1000")
nova.act("sort by price low to high")
nova.act("click on the first result")
nova.act("click add to cart")
```

### 2. Use Schemas for Data
```python
# ❌ Don't parse text manually
result = nova.act("What's the price?")
price = result.response.split('$')[1]  # Fragile!

# ✅ Use Pydantic schemas
class Price(BaseModel):
    amount: float
    
result = nova.act("What's the price?", schema=Price.model_json_schema())
if result.matches_schema:
    price = Price.model_validate(result.parsed_response)
```

### 3. Always Handle Errors
```python
from nova_act import ActError

try:
    with NovaAct(starting_page="https://example.com") as nova:
        nova.act("perform task")
except ActError as e:
    print(f"Error: {e}")
    # Handle appropriately
```

## Getting Help

- **Official Docs**: https://github.com/aws/nova-act
- **Bug Reports**: nova-act@amazon.com
- **GitHub Issues**: https://github.com/aws/nova-act/issues

## Pro Tips

1. **Start with headless=False** - See what Nova Act is doing
2. **Use logs_directory** - Keep organized records of runs
3. **Check for captchas** - Handle them with user intervention
4. **Test incrementally** - Build your script one act() at a time
5. **Use descriptive prompts** - "Click the blue 'Submit' button on the right"
6. **Read the traces** - Learn from what worked and what didn't

## Ready to Build?

Now that you're set up, you can:

1. Ask Claude to generate custom Nova Act scripts for your needs
2. Modify the example scripts for your use cases
3. Build automation workflows for your daily tasks
4. Create monitoring scripts for websites you care about

Happy automating! 🚀
