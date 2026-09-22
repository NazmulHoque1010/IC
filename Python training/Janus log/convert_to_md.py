import shutil

def convert_log_to_md(log_path, md_path):
    # copy2 preserves the exact contents as well as file metadata (timestamps)
    shutil.copy2(log_path, md_path)
    print(f"Successfully created {md_path} with the exact contents of {log_path}")

if __name__ == "__main__":
    # Define your file paths here
    input_log_file = r"C:\Users\Lenovo\Desktop\IC\Python training\Janus log\unique_occurrences.log"
    output_md_file = r"C:\Users\Lenovo\Desktop\IC\Python training\Janus log\unique.md"
    
    convert_log_to_md(input_log_file, output_md_file)