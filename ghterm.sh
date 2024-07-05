#!/bin/bash

# Check if gh CLI is installed
if ! command -v gh &> /dev/null; then
    echo "GitHub CLI (gh) is not installed. Please install it first."
    exit 1
fi

# Global variables
EDITOR=""
EDITOR_SET=false

# Function to handle errors
handle_error() {
    dialog --title "Error" --msgbox "$1" 8 50
}

# Function to set up the editor
setup_editor() {
    if [ "$EDITOR_SET" = true ]; then
        dialog --msgbox "Editor is already set to: $EDITOR" 6 40
        return 0
    fi
    
    local editors=("nano" "vim" "code" "gedit" "custom")
    local editor_choice=$(dialog --clear --title "Setup Editor" \
        --menu "Choose your preferred editor:" 15 40 5 \
        1 "nano" \
        2 "vim" \
        3 "VS Code" \
        4 "gedit" \
        5 "Custom" \
        2>&1 >/dev/tty)

    case $editor_choice in
        1) EDITOR="nano" ;;
        2) EDITOR="vim" ;;
        3) EDITOR="code" ;;
        4) EDITOR="gedit" ;;
        5) 
            EDITOR=$(dialog --title "Custom Editor" \
                --inputbox "Enter the command to launch your editor:" 8 40 \
                2>&1 >/dev/tty)
            ;;
        *) return 1 ;;
    esac

    EDITOR_SET=true
    dialog --msgbox "Editor set to: $EDITOR" 6 40
}

# Function to handle GitHub login
github_login() {
    if gh auth status &> /dev/null; then
        dialog --msgbox "Already logged in to GitHub." 6 40
    else
        gh auth login -w
        if [ $? -eq 0 ]; then
            dialog --msgbox "Successfully logged in to GitHub." 6 40
        else
            handle_error "Failed to log in to GitHub."
            return 1
        fi
    fi
}

# Function to get user info
get_user_info() {
    USER_INFO=$(gh api user)
    USERNAME=$(echo $USER_INFO | jq -r .login)
}

# Function to view repositories and their contents
view_repositories() {
    while true; do
        local repos=$(gh repo list --json name --jq '.[].name')
        local repo_array=()
        local i=1
        while read -r repo; do
            repo_array+=($i "$repo")
            ((i++))
        done <<< "$repos"

        repo_array+=($i "Go back")

        local repo_choice=$(dialog --clear --title "Your Repositories" \
            --menu "Choose a repository to view:" 20 60 10 \
            "${repo_array[@]}" \
            2>&1 >/dev/tty)

        if [ $? -ne 0 ] || [ "$repo_choice" -eq $i ]; then
            return
        fi

        local selected_repo=${repo_array[$(( repo_choice * 2 - 1 ))]}
        view_repository_contents "$selected_repo"
    done
}

# Function to view repository contents
view_repository_contents() {
    local repo=$1
    local path=""
    
    while true; do
        local files=$(gh api "repos/$USERNAME/$repo/contents/$path" --jq '.[] | "\(.type)|\(.name)|\(.path)"')
        local file_array=()
        local i=1
        while IFS='|' read -r type name filepath; do
            file_array+=($i "$name ($type)")
            ((i++))
        done <<< "$files"

        file_array+=($i "Go back")

        local file_choice=$(dialog --clear --title "Repository: $repo" \
            --menu "Current path: /$path\nChoose a file or directory:" 20 60 10 \
            "${file_array[@]}" \
            2>&1 >/dev/tty)

        if [ $? -ne 0 ] || [ "$file_choice" -eq $i ]; then
            return
        fi

        local selected_file=${file_array[$(( file_choice * 2 - 1 ))]}
        selected_file=${selected_file% (*}  # Remove the (type) suffix

        local file_type=${file_array[$(( file_choice * 2 ))]}
        file_type=${file_type#*(}
        file_type=${file_type%)}

        if [ "$file_type" = "dir" ]; then
            path="${path:+$path/}$selected_file"
        else
            edit_file "$repo" "$path/$selected_file"
        fi
    done
}

# Function to edit a file
edit_file() {
    local repo=$1
    local filepath=$2

    [ -z "$EDITOR" ] && setup_editor

    local temp_file=$(mktemp)
    gh api "repos/$USERNAME/$repo/contents/$filepath" --jq '.content' | base64 -d > "$temp_file"
    $EDITOR "$temp_file"

    if [ $? -eq 0 ]; then
        if dialog --yesno "Do you want to commit these changes?" 6 40; then
            local commit_message=$(dialog --title "Commit Message" \
                --inputbox "Enter commit message:" 8 40 \
                2>&1 >/dev/tty)
            gh api --method PUT "repos/$USERNAME/$repo/contents/$filepath" \
                -f message="$commit_message" \
                -f content="$(base64 -w 0 "$temp_file")" \
                --silent
            dialog --msgbox "Changes committed successfully." 6 40
        fi
    fi
    rm "$temp_file"
}

# Function to create a repository
create_repository() {
    local repo_name=$(dialog --title "Create Repository" \
        --inputbox "Enter repository name:" 8 40 \
        2>&1 >/dev/tty)
    
    if [ $? -ne 0 ]; then return; fi

    local visibility=$(dialog --title "Repository Visibility" \
        --menu "Choose visibility:" 10 40 2 \
        1 "Private" \
        2 "Public" \
        2>&1 >/dev/tty)
    
    if [ $? -ne 0 ]; then return; fi

    local vis_flag="--private"
    [ "$visibility" -eq 2 ] && vis_flag="--public"
    
    if gh repo create "$repo_name" $vis_flag; then
        dialog --title "Create Repository" \
            --msgbox "Repository '$repo_name' created successfully." 8 50
    else
        handle_error "Failed to create repository '$repo_name'."
    fi
}

# Function to clone a repository
clone_repository() {
    local repo_url=$(dialog --title "Clone Repository" \
        --inputbox "Enter repository URL or name:" 8 50 \
        2>&1 >/dev/tty)
    
    if [ $? -ne 0 ]; then return; fi

    if gh repo clone "$repo_url"; then
        dialog --title "Clone Repository" \
            --msgbox "Repository cloned from '$repo_url'." 8 50
    else
        handle_error "Failed to clone repository from '$repo_url'."
    fi
}

# Function to pull repository
pull_repository() {
    local repo_name=$(dialog --title "Pull Repository" \
        --inputbox "Enter repository name:" 8 40 \
        2>&1 >/dev/tty)
    
    if [ $? -ne 0 ]; then return; fi

    local output=$(gh repo sync "$USERNAME/$repo_name" 2>&1)
    dialog --title "Pull Repository" \
        --msgbox "Pull result for '$repo_name':\n$output" 10 60
}

# Function to track and push changes
push_changes() {
    local repo_name=$(dialog --title "Push Changes" \
        --inputbox "Enter repository name:" 8 40 \
        2>&1 >/dev/tty)
    
    if [ $? -ne 0 ]; then return; fi

    if [ -z "$EDITOR" ]; then
        setup_editor
    fi

    local changes=$(git -C "$repo_name" status --porcelain)
    
    if [ -n "$changes" ]; then
        dialog --title "Changes" --msgbox "Changes detected:\n$changes" 10 60
        git -C "$repo_name" add .
        
        local commit_message=$(dialog --title "Commit Message" \
            --inputbox "Enter commit message:" 8 40 \
            2>&1 >/dev/tty)
        
        git -C "$repo_name" commit -m "$commit_message"
        git -C "$repo_name" push
        
        dialog --msgbox "Changes pushed to the repository." 6 40
    else
        dialog --msgbox "No changes to push." 6 40
    fi
}

# Function to create a pull request
create_pull_request() {
    local repo_name=$(dialog --title "Select Repository" \
        --inputbox "Enter repository name:" 8 40 \
        2>&1 >/dev/tty)
    
    if [ $? -ne 0 ]; then return; fi

    local title=$(dialog --title "Pull Request Title" \
        --inputbox "Enter pull request title:" 8 40 \
        2>&1 >/dev/tty)
    
    if [ $? -ne 0 ]; then return; fi

    local body=$(dialog --title "Pull Request Body" \
        --inputbox "Enter pull request description:" 8 40 \
        2>&1 >/dev/tty)
    
    if [ $? -ne 0 ]; then return; fi

    local output=$(gh pr create -R "$USERNAME/$repo_name" -t "$title" -b "$body" 2>&1)
    dialog --title "Create Pull Request" \
        --msgbox "Pull request created:\n$output" 10 60
}

# Function to view pull requests for the user
view_pull_requests() {
    local prs=$(gh pr list --json number,title,state -q '.[] | "\(.number) - \(.title) (\(.state))"')
    dialog --title "Pull Requests" \
        --msgbox "Pull Requests:\n$prs" 20 70
}

# Function to view issues for the user
view_issues() {
    local issues=$(gh issue list --json number,title,state -q '.[] | "\(.number) - \(.title) (\(.state))"')
    dialog --title "Issues" \
        --msgbox "Issues:\n$issues" 20 70
}

# Function to create an issue
create_issue() {
    local repos=$(gh repo list --json name --jq '.[].name')
    local repo_array=()
    local i=1
    while read -r repo; do
        repo_array+=($i "$repo")
        ((i++))
    done <<< "$repos"

    repo_array+=($i "Go back")

    local repo_choice=$(dialog --clear --title "Create Issue" \
        --menu "Choose a repository:" 20 60 10 \
        "${repo_array[@]}" \
        2>&1 >/dev/tty)

    if [ $? -ne 0 ] || [ "$repo_choice" -eq $i ]; then
        return
    fi

    local selected_repo=${repo_array[$(( repo_choice * 2 - 1 ))]}

    local title=$(dialog --title "Issue Title" \
        --inputbox "Enter issue title:" 8 40 \
        2>&1 >/dev/tty)
    
    if [ $? -ne 0 ]; then return; fi

    local body=$(dialog --title "Issue Body" \
        --inputbox "Enter issue description:" 8 40 \
        2>&1 >/dev/tty)
    
    if [ $? -ne 0 ]; then return; fi

    local output=$(gh issue create -R "$USERNAME/$selected_repo" -t "$title" -b "$body" 2>&1)
    dialog --title "Create Issue" \
        --msgbox "Issue created:\n$output" 10 60
}

# Function to delete a repository
delete_repository() {
    while true; do
        local repos=$(gh repo list --json name --jq '.[].name')
        local repo_array=()
        local i=1
        while read -r repo; do
            repo_array+=($i "$repo")
            ((i++))
        done <<< "$repos"

        repo_array+=($i "Go back")

        local repo_choice=$(dialog --clear --title "Delete Repository" \
            --menu "Choose a repository to delete:" 20 60 10 \
            "${repo_array[@]}" \
            2>&1 >/dev/tty)

        if [ $? -ne 0 ] || [ "$repo_choice" -eq $i ]; then
            return
        fi

        local selected_repo=${repo_array[$(( repo_choice * 2 - 1 ))]}

        if dialog --title "Confirm Deletion" \
            --yesno "Are you sure you want to delete the repository '$selected_repo'?\nThis action cannot be undone!" 8 60; then
            local output=$(gh repo delete "$USERNAME/$selected_repo" --confirm 2>&1)
            if [ $? -eq 0 ]; then
                dialog --title "Repository Deleted" \
                    --msgbox "Repository '$selected_repo' has been deleted.\n$output" 8 60
            else
                handle_error "Failed to delete repository '$selected_repo'.\n$output"
            fi
        else
            dialog --title "Deletion Cancelled" \
                --msgbox "Deletion of '$selected_repo' has been cancelled." 6 50
        fi
    done
}

# Function to logout
logout() {
    if dialog --yesno "Are you sure you want to log out?" 6 40; then
        gh auth logout
        dialog --msgbox "You have been logged out from GitHub." 6 40
    fi
}

# Main menu function
show_main_menu() {
    while true; do
        if ! gh auth status &> /dev/null; then
            local choice=$(dialog --clear --title "Terminal GitHub" \
                --menu "Choose an option:" 15 50 3 \
                1 "Login to GitHub" \
                2 "Setup Editor" \
                3 "Exit" \
                2>&1 >/dev/tty)

            case $choice in
                1) github_login ;;
                2) setup_editor ;;
                3) exit 0 ;;
                *) continue ;;
            esac
        else
            get_user_info
            local choice=$(dialog --clear --title "Terminal GitHub" \
                --menu "Logged in as $USERNAME. Choose an option:" 20 60 13 \
                1 "View Repositories" \
                2 "Create Repository" \
                3 "Clone Repository" \
                4 "Pull Repository" \
                5 "Push Changes" \
                6 "Create Pull Request" \
                7 "View Pull Requests" \
                8 "View Issues" \
                9 "Create Issue" \
                10 "Delete Repository" \
                11 "Setup Editor" \
                12 "Logout" \
                13 "Exit" \
                2>&1 >/dev/tty)

            case $choice in
                1) view_repositories ;;
                2) create_repository ;;
                3) clone_repository ;;
                4) pull_repository ;;
                5) push_changes ;;
                6) create_pull_request ;;
                7) view_pull_requests ;;
                8) view_issues ;;
                9) create_issue ;;
                10) delete_repository ;;
                11) setup_editor ;;
                12) logout ;;
                13) exit 0 ;;
                *) continue ;;
            esac
        fi
    done
}

# Start the application
show_main_menu
