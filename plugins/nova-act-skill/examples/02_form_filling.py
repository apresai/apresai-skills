#!/usr/bin/env python3
"""
Nova Act Example: Automated Job Application Form Filler

This script demonstrates:
- Persisting authentication/browser state
- Form filling with structured data
- Multi-step form navigation
- Captcha detection and handling

Prerequisites:
- Nova Act SDK: pip install nova-act
- API key: export NOVA_ACT_API_KEY="your_key"
"""

from nova_act import NovaAct, BOOL_SCHEMA, ActError
from pydantic import BaseModel
from typing import Optional
import os
import getpass


class ApplicantInfo(BaseModel):
    """Data model for job applicant information"""
    full_name: str
    email: str
    phone: str
    address: str
    city: str
    state: str
    zip_code: str
    current_position: str
    years_experience: int
    linkedin_url: Optional[str] = None
    cover_letter: str


def setup_authenticated_session(user_data_dir: str, job_site_url: str):
    """
    Setup an authenticated browser session for reuse.
    This only needs to be run once to log in and save the session.
    """
    print("Setting up authenticated session...")
    print("You will need to log in manually.")
    
    os.makedirs(user_data_dir, exist_ok=True)
    
    with NovaAct(
        starting_page=job_site_url,
        user_data_dir=user_data_dir,
        clone_user_data_dir=False,  # Don't clone - we want to save state
        headless=False  # Show browser so user can log in
    ) as nova:
        print("\nPlease log into the website...")
        input("Press Enter after you've logged in...")
        
        # Verify login
        result = nova.act("Am I logged in to my account?", schema=BOOL_SCHEMA)
        if result.matches_schema and result.parsed_response:
            print("✓ Login successful! Session saved.")
        else:
            print("✗ Could not verify login status")
    
    print(f"Session data saved to: {user_data_dir}")


def check_for_captcha(nova: NovaAct) -> bool:
    """Check if there's a captcha on the current page"""
    result = nova.act(
        "Is there a captcha or human verification challenge on this page?",
        schema=BOOL_SCHEMA
    )
    return result.matches_schema and result.parsed_response


def fill_job_application(
    job_url: str,
    applicant: ApplicantInfo,
    user_data_dir: str,
    resume_path: Optional[str] = None
) -> bool:
    """
    Fill out a job application form using saved authentication.
    
    Args:
        job_url: URL of the job posting
        applicant: Applicant information
        user_data_dir: Path to saved browser profile
        resume_path: Optional path to resume file
    
    Returns:
        True if application submitted successfully
    """
    try:
        with NovaAct(
            starting_page=job_url,
            user_data_dir=user_data_dir,
            clone_user_data_dir=True,  # Clone for safety
            headless=False,  # Show browser to monitor progress
            logs_directory="./logs/job_application"
        ) as nova:
            print(f"Navigating to: {job_url}")
            
            # Step 1: Find and click the "Apply" button
            nova.act("click on the 'Apply' or 'Apply Now' button")
            
            # Step 2: Check for captcha
            if check_for_captcha(nova):
                print("⚠ Captcha detected!")
                input("Please solve the captcha, then press Enter to continue...")
            
            # Step 3: Fill in personal information
            print("Filling personal information...")
            nova.act(f"Fill in the full name field with '{applicant.full_name}'")
            nova.act(f"Fill in the email field with '{applicant.email}'")
            nova.act(f"Fill in the phone number field with '{applicant.phone}'")
            
            # Step 4: Fill in address information
            print("Filling address information...")
            nova.act(f"Fill in the address field with '{applicant.address}'")
            nova.act(f"Fill in the city field with '{applicant.city}'")
            nova.act(f"Select '{applicant.state}' from the state dropdown")
            nova.act(f"Fill in the zip code with '{applicant.zip_code}'")
            
            # Step 5: Check if we need to proceed to next page
            result = nova.act(
                "Is there a 'Next' or 'Continue' button visible?",
                schema=BOOL_SCHEMA
            )
            if result.matches_schema and result.parsed_response:
                nova.act("click the 'Next' or 'Continue' button")
            
            # Step 6: Fill in professional information
            print("Filling professional information...")
            nova.act(f"Fill in current job title with '{applicant.current_position}'")
            nova.act(f"Fill in years of experience with '{applicant.years_experience}'")
            
            if applicant.linkedin_url:
                nova.act(f"Fill in LinkedIn URL with '{applicant.linkedin_url}'")
            
            # Step 7: Upload resume if provided
            if resume_path and os.path.exists(resume_path):
                print(f"Uploading resume: {resume_path}")
                nova.page.set_input_files('input[type="file"]', resume_path)
                # Wait for upload to complete
                nova.act("wait for any upload indicators to complete")
            
            # Step 8: Fill in cover letter
            print("Filling cover letter...")
            nova.act(f"Find the cover letter text area and fill it with: {applicant.cover_letter}")
            
            # Step 9: Check for captcha again
            if check_for_captcha(nova):
                print("⚠ Captcha detected!")
                input("Please solve the captcha, then press Enter to continue...")
            
            # Step 10: Review before submission
            print("\nApplication filled. Ready to submit...")
            
            # Take a screenshot for review
            screenshot_path = "./logs/application_review.png"
            nova.page.screenshot(path=screenshot_path)
            print(f"Screenshot saved to: {screenshot_path}")
            
            # Ask user for confirmation
            submit = input("Submit application? (yes/no): ").lower().strip()
            
            if submit == 'yes':
                print("Submitting application...")
                nova.act("click the 'Submit' or 'Submit Application' button")
                
                # Verify submission
                result = nova.act(
                    "Do you see a confirmation message that the application was submitted?",
                    schema=BOOL_SCHEMA
                )
                
                if result.matches_schema and result.parsed_response:
                    print("✓ Application submitted successfully!")
                    # Take confirmation screenshot
                    nova.page.screenshot(path="./logs/application_confirmed.png")
                    return True
                else:
                    print("⚠ Could not verify submission")
                    return False
            else:
                print("Application not submitted (user cancelled)")
                return False
                
    except ActError as e:
        print(f"Error filling application: {e}")
        return False


def main():
    """Main execution"""
    
    # Configuration
    user_data_dir = "/tmp/job_site_profile"
    job_site_url = "https://www.linkedin.com/jobs"  # Example - change as needed
    
    # Sample applicant data
    applicant = ApplicantInfo(
        full_name="Jane Doe",
        email="jane.doe@example.com",
        phone="555-0123",
        address="123 Main Street",
        city="San Francisco",
        state="CA",
        zip_code="94102",
        current_position="Senior Software Engineer",
        years_experience=8,
        linkedin_url="https://linkedin.com/in/janedoe",
        cover_letter=(
            "I am excited to apply for this position. With 8 years of experience "
            "in software engineering, I have developed strong skills in Python, "
            "cloud architecture, and team leadership. I am passionate about building "
            "scalable systems and would love to contribute to your team."
        )
    )
    
    # Check if we need to setup authentication
    if not os.path.exists(user_data_dir):
        print("No saved session found. Setting up authentication...")
        setup_authenticated_session(user_data_dir, job_site_url)
    else:
        print("Using saved authentication session")
    
    # Example job URLs to apply to
    job_urls = [
        "https://example.com/jobs/senior-software-engineer",
        # Add more job URLs here
    ]
    
    # Apply to each job
    results = []
    for i, job_url in enumerate(job_urls, 1):
        print(f"\n{'='*60}")
        print(f"Application {i} of {len(job_urls)}")
        print(f"{'='*60}\n")
        
        success = fill_job_application(
            job_url=job_url,
            applicant=applicant,
            user_data_dir=user_data_dir,
            resume_path="./resume.pdf"  # Optional
        )
        
        results.append({
            'url': job_url,
            'success': success
        })
    
    # Summary
    print(f"\n{'='*60}")
    print("SUMMARY")
    print(f"{'='*60}")
    successful = sum(1 for r in results if r['success'])
    print(f"Applications submitted: {successful}/{len(results)}")
    
    for i, result in enumerate(results, 1):
        status = "✓" if result['success'] else "✗"
        print(f"{status} Application {i}: {result['url']}")
    
    return 0


if __name__ == "__main__":
    exit(main())
