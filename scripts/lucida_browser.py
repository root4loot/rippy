#!/usr/bin/env python3

import sys
import json
import time
import re
import os
from urllib.parse import quote
import undetected_chromedriver as uc
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium_stealth import stealth
import requests
import logging

logging.basicConfig(level=logging.INFO, format='%(levelname)s: %(message)s')

def setup_driver():
    options = uc.ChromeOptions()
    options.add_argument('--headless')
    options.add_argument('--no-sandbox')
    options.add_argument('--disable-dev-shm-usage')
    options.add_argument('--disable-blink-features=AutomationControlled')
    options.add_argument('--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36')

    # Try to find Chrome/Chromium binary
    import shutil
    chrome_paths = [
        '/usr/bin/google-chrome',
        '/usr/bin/google-chrome-stable',
        '/usr/bin/chromium',
        '/usr/bin/chromium-browser',
        '/snap/bin/chromium',
        shutil.which('google-chrome'),
        shutil.which('chromium'),
        shutil.which('chromium-browser')
    ]

    chrome_binary = None
    for path in chrome_paths:
        if path and os.path.exists(path):
            chrome_binary = path
            break

    if chrome_binary:
        options.binary_location = chrome_binary
        logging.info(f"Using Chrome binary: {chrome_binary}")
    else:
        logging.warning("Chrome binary not found, trying default location")

    try:
        driver = uc.Chrome(options=options, version_main=None)
    except Exception as e:
        logging.error(f"Failed to create Chrome driver: {e}")
        logging.info("Trying with regular Chrome driver as fallback")
        # Fallback to regular selenium Chrome
        from selenium.webdriver import Chrome
        from selenium.webdriver.chrome.service import Service
        driver = Chrome(options=options)

    stealth(driver,
            languages=["en-US", "en"],
            vendor="Google Inc.",
            platform="Win32",
            webgl_vendor="Intel Inc.",
            renderer="Intel Iris OpenGL Engine",
            fix_hairline=True,
    )

    return driver

def get_redirect_with_browser(driver, spotify_url, service):
    encoded_url = quote(spotify_url, safe='')
    lucida_url = f"https://lucida.to/?url={encoded_url}&country=auto&to={service}"

    logging.info(f"Navigating to lucida.to with service: {service}")
    driver.get(lucida_url)

    time.sleep(3)

    wait = WebDriverWait(driver, 60)  # Increased for Cloudflare challenges

    try:
        wait.until(lambda driver: driver.current_url != lucida_url)
    except:
        pass

    current_url = driver.current_url
    logging.info(f"Current URL after navigation: {current_url}")

    if "failed-to=" in current_url:
        logging.info(f"Track not available on {service}")
        return None

    match = re.search(r'url=([^&]+)', current_url)
    if match:
        service_url = match.group(1).replace('%3A', ':').replace('%2F', '/')
        logging.info(f"Extracted service URL: {service_url}")
        return service_url

    return None

def initiate_download(service_url):
    current_time = int(time.time())
    expiry = current_time + 86400

    post_data = {
        "url": service_url,
        "metadata": True,
        "compat": False,
        "private": True,
        "handoff": True,
        "account": {"type": "country", "id": "auto"},
        "upload": {"enabled": False, "service": "pixeldrain"},
        "downscale": "original",
        "token": {"primary": "y5STwMUrIXJZ6yb5xYHh3VEiM-c", "expiry": expiry}
    }

    headers = {
        "Content-Type": "text/plain;charset=UTF-8",
        "Origin": "https://lucida.to",
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    }

    logging.info("Sending POST request to initiate download")
    response = requests.post(
        "https://lucida.to/api/load?url=/api/fetch/stream/v2",
        headers=headers,
        data=json.dumps(post_data)
    )

    if response.status_code != 200:
        logging.error(f"POST request failed with status: {response.status_code}")
        return None

    data = response.json()
    logging.debug(f"POST response: {data}")

    request_id = data.get('handoff') or data.get('id')
    server_name = data.get('name', 'hund')

    if not request_id:
        logging.error("Failed to get request/handoff ID")
        return None

    logging.info(f"Got handoff ID: {request_id} on server: {server_name}")
    return {"request_id": request_id, "server_name": server_name}

def poll_status(request_id, server_name):
    status_url = f"https://{server_name}.lucida.to/api/fetch/request/{request_id}"
    status = "started"
    poll_count = 0
    max_polls = 120

    while status != "completed" and poll_count < max_polls:
        time.sleep(2)
        poll_count += 1

        response = requests.get(status_url)
        if response.status_code != 200:
            logging.error(f"Status request failed with status: {response.status_code}")
            continue

        data = response.json()
        logging.debug(f"Status response: {data}")

        status = data.get('status', '')
        message = data.get('message', '')

        if not status:
            success = data.get('success', False)
            status = "working" if success else "error"

        logging.info(f"Status: {status} - {message}")

        if status in ["error", "failed"]:
            logging.error(f"Download failed with status: {status}")
            return False

        if status == "completed":
            return True

    logging.error("Download timed out")
    return False

def download_file(request_id, server_name, output_path):
    download_url = f"https://{server_name}.lucida.to/api/fetch/request/{request_id}/download"

    headers = {
        "Origin": "https://lucida.to",
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    }

    logging.info(f"Downloading file to {output_path}")
    response = requests.get(download_url, headers=headers, stream=True)

    if response.status_code != 200:
        logging.error(f"Download failed with status: {response.status_code}")
        return False

    with open(output_path, 'wb') as f:
        for chunk in response.iter_content(chunk_size=8192):
            f.write(chunk)

    logging.info(f"Successfully downloaded to {output_path}")
    return True

def main():
    if len(sys.argv) < 5:
        print("Usage: lucida_browser.py <spotify_url> <service> <artist> <title> <output_dir>", file=sys.stderr)
        sys.exit(1)

    spotify_url = sys.argv[1]
    service = sys.argv[2]
    artist = sys.argv[3]
    title = sys.argv[4]
    output_dir = sys.argv[5] if len(sys.argv) > 5 else "."

    driver = None
    try:
        driver = setup_driver()

        service_url = get_redirect_with_browser(driver, spotify_url, service)
        if not service_url:
            sys.exit(1)

        download_info = initiate_download(service_url)
        if not download_info:
            sys.exit(1)

        if not poll_status(download_info['request_id'], download_info['server_name']):
            sys.exit(1)

        safe_artist = artist.replace('/', '_')
        safe_title = title.replace('/', '_')
        extension = "mp3" if service == "soundcloud" else "flac"
        output_path = f"{output_dir}/{safe_artist} - {safe_title}.{extension}"

        if not download_file(download_info['request_id'], download_info['server_name'], output_path):
            sys.exit(1)

        result = {
            "path": output_path,
            "artist": artist,
            "title": title,
            "service": service
        }
        print(json.dumps(result))

    except Exception as e:
        logging.error(f"Error: {e}")
        sys.exit(1)
    finally:
        if driver:
            driver.quit()

if __name__ == "__main__":
    main()