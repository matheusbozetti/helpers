#!/bin/bash

# Using the script
#    curl -sSL https://raw.githubusercontent.com/matheusbozetti/helpers/create_symlinks.sh | bash
# OR
#    wget -qO- https://raw.githubusercontent.com/matheusbozetti/helpers/create_symlinks.sh | bash

# Source dir
source_dir="/etc/nginx/sites-available"

# Target Dir
target_dir="/etc/nginx/sites-enabled"

# Check dirs
if [ ! -d "$source_dir" ] || [ ! -d "$target_dir" ]; then
    echo "Diretórios de origem ou destino não existem."
    exit 1
fi

# Get files
for file in "$source_dir"/*; do
    filename=$(basename "$file")
    
    # Check existent file
    if [ -e "$target_dir/$filename" ]; then
        echo "The file $filename has an existent symlink."
    else
        # Cria o link simbólico no diretório de destino
        sudo ln -s "$file" "$target_dir/$filename"
        echo "Symlink created for the file $filename"
    fi
done


