#!/bin/bash

# Using the script
#    curl -sSL https://raw.githubusercontent.com/matheusbozetti/helpers/main/clear_broken_symlinks.sh | bash
# OR
#    wget -qO- https://raw.githubusercontent.com/matheusbozetti/helpers/main/clear_broken_symlinks.sh | bash
sudo find . -xtype l -delete
