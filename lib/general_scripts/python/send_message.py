#!/usr/bin/env python3

import os
import sys
import smtplib
from email.message import EmailMessage

SMTP_HOST = "smtp.yourdomain.com"
# Using the STARTTLS server
SMTP_PORT = 587
SMTP_USER = os.environ["SMTP_USER"]
SMTP_PASS = os.environ["SMTP_PASS"]

FROM = "nmrprague@seznam.cz"
TO = "luke@bubaci.net"
BODY = """"""

def main() -> None:
    # Check that correct number of params were provided
    if len(sys.argv) != 2:
        print(f"Usage: python {sys.argv[0]} JOB_NAME")
        sys.exit(1)

    # Load the parameters of the script
    job_name: str = sys.argv[1]

    # Set the mail subject
    subject = "Job "+job_name+" has finished!"

    msg = EmailMessage()
    msg["From"] = FROM
    msg["To"] = TO
    msg["Subject"] = subject
    msg.set_content(BODY)

    # Connect to SMTP server with STARTTLS
    with smtplib.SMTP(SMTP_HOST, SMTP_PORT) as smtp:
        smtp.ehlo()
        smtp.starttls()            # upgrade connection to TLS
        smtp.login(SMTP_USER, SMTP_PASS)
        smtp.send_message(msg)

if __name__ == "__main__":
    main()
