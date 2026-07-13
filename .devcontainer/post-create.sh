#!/bin/bash
set -e

# Install Zava web app dependencies
pip install --upgrade pip
pip install -r src/web/requirements.txt
