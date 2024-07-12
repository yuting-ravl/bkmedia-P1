#!/bin/bash

CONFIG_FILE="locations.cfg"
BACKUP_DIR="/vagrant/backups"
RESTORE_DIR="/vagrant/restores"
CHECKSUM_FILE="checksums.txt"
LOG_FILE="phantom_log.txt"

# Make sure the backups and restores folders exist
if [ ! -d "$BACKUP_DIR" ]; then
    mkdir -p "$BACKUP_DIR"
fi

if [ ! -d "$RESTORE_DIR" ]; then
    mkdir -p "$RESTORE_DIR"
fi

# Make sure the checksum and log files exist
if [ ! -f "$CHECKSUM_FILE" ]; then
    touch "$CHECKSUM_FILE"
fi

if [ ! -f "$LOG_FILE" ]; then
    touch "$LOG_FILE"
fi


# Display the directories in locations.cfg file
display_locations() {
    echo "Configured Locations:"
    nl -w 2 -s '. ' $CONFIG_FILE
}

# Function to check file integrity
check_integrity() {
    local directory="$1"
    local new_checksum old_checksum

    # Capture the list of files in the specified directory
    files=$(find "$directory" -type f)

    # Loop through each file in the list
    for file in $files; do
        # Generate new checksum for the file
        new_checksum=$(md5sum "$file" | cut -d' ' -f1)
        #echo "Checksum generated for $(basename "$file"): $new_checksum -------------- AFTER BACKUP"

        # Retrieve old checksum from CHECKSUM_FILE
        old_checksum=$(grep "$(basename "$file")" "$CHECKSUM_FILE" | cut -d' ' -f1)

        # Compare new_checksum to the old_checksum
        if [ "$new_checksum" != "$old_checksum" ]; then
            echo "FOUND PHANTOM!! - $file"
            echo "$file" >> "$LOG_FILE"
            echo "Original: $old_checksum" >> "$LOG_FILE"
            echo "New: $new_checksum" >> "$LOG_FILE"
            echo "File $file has been altered." >> "$LOG_FILE"
            mv "$file" "$file.phantom"
        else
            echo "INTEGRITY CHECK PASS - $file"
        fi
    done
    echo -e "\n\n"
}

# Function to generate integrity checksums for files in a directory on a remote host
generate_integrity() {
    local host_g=$(echo "$1" | cut -d':' -f1)
    local directory_g=$(echo "$1" | cut -d':' -f2-)
 
    echo "Generating integrity checksums for files in $directory_g..."

    # Get the list of files from the remote host
    files=$(ssh "$host_g" "find '$directory_g' -type f")

    # Loop through each file in the list
    for file in $files; do
        # Calculate MD5 checksum for the file on the remote host
        checksum=$(ssh "$host_g" "md5sum '$file' | cut -d' ' -f1")
        #echo "Checksum generated for $(basename "$file"): $checksum -------------- BEFORE BACKUP"

        # Update or append checksum to the checksum file on the local machine
        if grep -q "$(basename "$file")" "$CHECKSUM_FILE"; then
            # If the filename exists in the checksum file, update the checksum
            sed -i "s|.* $(basename "$file")|$checksum $(basename "$file")|" "$CHECKSUM_FILE"
            #echo "$checksum $(basename "$file") [updated]"
        else
            # If the filename does not exist in the checksum file
            echo "$checksum $(basename "$file")" >> "$CHECKSUM_FILE"
           # echo "$checksum $(basename "$file") [new]"
        fi
    done
}

# Function to back up a single location
backup_location() {
    local location="$1"
    local user host path timestamp dest

    # Extract user, host, and path from the location string
    user=$(echo "$location" | cut -d@ -f1)
    host=$(echo "$location" | cut -d@ -f2 | cut -d: -f1)
    path=$(echo "$location" | cut -d: -f2)

    # Create a timestamp for the backup
    timestamp=$(date +"%Y%m%d%H%M%S")

    # Construct the destination directory path
    dest="$BACKUP_DIR/$(echo "$host" | tr '.' '_')_$(basename "$path")_$timestamp"

    # Output backup progress
    echo "Backing up $user@$host:$path to $dest"

    # Ensure the destination directory exists
    mkdir -p "$dest"

    # Generate integrity of files before backing up
    generate_integrity "$user@$host:$path"

    # Perform the backup using SSH and rsync (copy files directly)
    echo -e "\n++++++++++++ BACKING UP ++++++++++++"
    ssh "$user@$host" "rsync -avz '$path/' $dest/"
    echo -e "+++++++++++ END OF BACK UP +++++++++++\n"

    # Generate integrity of files after backing up and Compare two checksum files
    echo "Comparing two checksum"
    check_integrity "$dest/"
}

# Function to back up all locations listed in the config file
backup_all() {
    local line location
    local line_number=1

    for location in $(cat "$CONFIG_FILE"); do

        # Print each location for debugging purposes
        echo "Processing line $line_number: $location"

        backup_location "$location"
        ((line_number++))
    done
}

# Function to restore
restore() {
    certain_version_to_restore="$1"
    certain_location_to_restore="$2"

    # Declare an array and store unique location retrieved from CONFIG_FILE
    declare -A location_array
    # Declare associative array to store unique VM IPs for later use to match folder name in /backups
    declare -A vm_ips
    line_number=1

    for location in $(cat "$CONFIG_FILE"); do
        location_array["$line_number"]="$location"

        host=$(echo "$location" | cut -d@ -f2 | cut -d: -f1 | tr '.' '_')
        vm_ips["$host"]=1
         ((line_number++))
    done

    if [ -n "$2" ]; then
       restore_host "$certain_version_to_restore" $(echo "${location_array[$2]}" | cut -d@ -f2 | cut -d: -f1 | tr '.' '_')
    else
       for host in "${!vm_ips[@]}"; do
          restore_host "$certain_version_to_restore" "$host"
       done
    fi
}

# Function to restore according to the target version for the target directory/host
restore_host() {
    # Set this version number to 1 for most recent, 2 for second most recent, etc.
    local target_version="$1"

    if [ -n "$2" ]; then
      host="$2"
    fi

    # Pattern to match backup folder prefix
    pattern="${host}_"
    target_recent_backup=$(ls -1t "$BACKUP_DIR" | grep "$pattern" | sed -n "${target_version}p")

    # Find the destination path from the CONFIG_FILE for this host
    host_address=$(echo "$host" | tr '_' '.')
    destination=$(grep "$host_address" "$CONFIG_FILE")

    # Exit the function if no backups are found
    #Code-Note: -z is to check if the variable is empty; -n is to check if the variable is non-empty
    if [ -z "$target_recent_backup" ]; then
        echo "No Such backups found for $host"
        echo "The requested backup version is $target_version"
        return
    fi

    # Ensure restore directory is empty before copying files from /backups
    rm -rf "$RESTORE_DIR"/*

    # Empty the files in destination to restore files
    echo "Directory: $destination"
    if [ -n "$destination" ]; then
      rm -rf "$destination"*
    fi

    # Copy the target version backup to the restore directory
    echo "Copying $target_recent_backup to $RESTORE_DIR for restore preparation"
    rsync -av "$BACKUP_DIR/$target_recent_backup/" "$RESTORE_DIR"

    # Sync the restored files to the destination
    echo "Restoring files to $destination"
    rsync -av "$RESTORE_DIR/" "$destination"

    echo "Restore completed for $host_address"
}

case "$1" in
    -B)
        # ./bkmedia -B -L 2
        if [ -n "$2" ] && [ "$2" == "-L" ] && [ -n "$3" ]; then
            echo "==============================="
            echo "Back up for certain location $3"
            echo "==============================="
            location=$(sed -n "${3}p" $CONFIG_FILE)
            backup_location "$location"
        elif [ -n "$2" ] && [ "$2" != "-L" ]; then
            echo "Invalid input: Please specify a line number as a parameter after the -L option."
        else
            # ./bkmedia -B
            echo "========================="
            echo "Back up for all locations"
            echo "========================="
	    backup_all
        fi
        ;;
    -R)
        if [ -n "$2" ] && [[ "$2" =~ ^[0-9]+$ ]]; then
            if [ "$3" == "-L" ] && [ -n "$4" ] && [[ "$4" =~ ^[0-9]+$ ]]; then
                # ./bkmedia -R 2 -L 2
                echo "============================================================================="
                echo "Restore certain location $4 with $2nd most recent version of the backup files"
                echo "============================================================================="
                restore "$2" "$4"
            else
                # ./bkmedia -R 2
                echo "========================================================"
                echo "Restore all with $2nd recent version of the backup files"
		echo "========================================================"
		restore "$2"
            fi
        else
            if [ "$2" == "-L" ] && [ -n "$3" ] && [[ "$3" =~ ^[0-9]+$ ]]; then
                # ./bkmedia -R -L 2
                echo "============================================================================"
                echo "Restore certain location $3 with the most recent version of the backup files"
                echo "============================================================================"
		restore "1" "$3"
            else
                # ./bkmedia -R
                echo "===================================================================="
                echo "Restore the most recent version of the backup files to all locations"
                echo "===================================================================="
		restore "1"
            fi
        fi
        ;;
    *)
        display_locations
        ;;
esac
