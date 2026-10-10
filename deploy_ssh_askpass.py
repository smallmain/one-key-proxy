#!/usr/bin/env python3
"""OpenSSH reads saved passwords through this helper, never through argv."""

import getpass
import os
import re
import sys

from deploy_credentials import Credentials
from deploy_resources import DeployError


def main():
    if len(sys.argv) != 2:
        return 1
    prompt = sys.argv[1]
    try:
        if re.fullmatch(r"(?:[A-Za-z0-9_.@:\[\]-]+'s )?[Pp]assword:\s*", prompt):
            from deploy import ResumeState
            credentials = Credentials(ResumeState(os.environ['OKP_SSH_CREDENTIAL_DIR']))
            password = credentials.ssh(os.environ['OKP_SSH_TARGET'], int(os.environ['OKP_SSH_PORT']))
            if password is None:
                return 1
        else:
            # Preserve interactive host-key confirmation and one-time challenges.
            with open('/dev/tty', 'r+', encoding='utf-8') as terminal:
                if 'yes/no' in prompt.lower():
                    terminal.write(prompt)
                    terminal.flush()
                    password = terminal.readline().rstrip('\n')
                else:
                    password = getpass.getpass(prompt, stream=terminal)
        sys.stdout.write(password + '\n')
        return 0
    except (DeployError, OSError, ValueError, KeyError, EOFError):
        return 1


if __name__ == '__main__':
    sys.exit(main())
