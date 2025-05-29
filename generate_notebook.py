#!/usr/bin/env python3
"""
Script to materialize Jinja2 template into a Jupyter notebook.
This script loads the verify_setup.ipynb.j2 template and generates
a concrete notebook file using the variables from notebook_vars.yml.
"""

import json
import os
import re
import sys
from pathlib import Path

import yaml
from jinja2 import Environment, FileSystemLoader, Template


def expand_env_vars(value):
    """Expand environment variables in the format ${VAR_NAME:-default_value}"""
    if not isinstance(value, str):
        return value

    # Pattern to match ${VAR_NAME:-default_value} or ${VAR_NAME}
    pattern = r"\$\{([^}]+)\}"

    def replace_var(match):
        var_expression = match.group(1)

        # Check if it has a default value (contains :-)
        if ":-" in var_expression:
            var_name, default_value = var_expression.split(":-", 1)
            return os.getenv(var_name, default_value)
        else:
            return os.getenv(var_expression, "")

    return re.sub(pattern, replace_var, value)


def expand_variables_recursively(data):
    """Recursively expand environment variables in nested dictionaries"""
    if isinstance(data, dict):
        return {key: expand_variables_recursively(value) for key, value in data.items()}
    elif isinstance(data, list):
        return [expand_variables_recursively(item) for item in data]
    else:
        return expand_env_vars(data)


def load_variables(vars_file: Path) -> dict:
    """Load variables from YAML file and expand environment variables."""
    try:
        with open(vars_file, "r") as f:
            raw_variables = yaml.safe_load(f)

        if not isinstance(raw_variables, dict):
            print("Error: YAML file must contain a dictionary at the root level.")
            sys.exit(1)

        # Expand environment variables in the loaded data
        expanded_variables = expand_variables_recursively(raw_variables)

        return expanded_variables
    except FileNotFoundError:
        print("Error: Variables file '{}' not found.".format(vars_file))
        sys.exit(1)
    except yaml.YAMLError as e:
        print("Error parsing YAML file: {}".format(e))
        sys.exit(1)


def load_template(template_file: Path) -> Template:
    """Load Jinja2 template with custom delimiters."""
    try:
        with open(template_file, "r") as f:
            template_content = f.read()

        env = Environment(
            loader=FileSystemLoader(template_file.parent),
            trim_blocks=True,
            lstrip_blocks=True,
            variable_start_string='<<',
            variable_end_string='>>',
            block_start_string='<%',
            block_end_string='%>',
            comment_start_string='<#',
            comment_end_string='#>'
        )
        return env.from_string(template_content)
    except FileNotFoundError:
        print("Error: Template file '{}' not found.".format(template_file))
        sys.exit(1)


def materialize_notebook(template: Template, variables: dict) -> dict:
    """Render the template with variables and return the notebook JSON."""
    try:
        rendered_content = template.render(**variables)
        return json.loads(rendered_content)
    except json.JSONDecodeError as e:
        print("Error: Generated notebook is not valid JSON: {}".format(e))
        sys.exit(1)
    except Exception as e:
        print("Error rendering template: {}".format(e))
        sys.exit(1)


def save_notebook(notebook: dict, output_file: Path) -> None:
    """Save the notebook to a file."""
    try:
        with open(output_file, "w") as f:
            json.dump(notebook, f, indent=2, ensure_ascii=False)
        print("✅ Successfully generated notebook: {}".format(output_file))
    except Exception as e:
        print("Error saving notebook: {}".format(e))
        sys.exit(1)


def validate_variables(variables: dict) -> None:
    """Validate that required variables are present."""
    required_vars = [
        ("notebook_vars.work_dir", "WORK_DIR"),
        ("notebook_vars.oc_api_url", "OC_API_URL"),
        ("notebook_vars.oc_catalog_name", "OC_CATALOG_NAME"),
        ("notebook_vars.demo_namespace", "DEMO_NAMESPACE"),
        ("notebook_vars.demo_table_name", "DEMO_TABLE_NAME"),
    ]

    missing_vars = []

    for var_path, env_var_name in required_vars:
        keys = var_path.split(".")
        current = variables
        found_in_yaml = True

        # Check if variable exists in YAML structure
        try:
            for key in keys:
                current = current[key]

            # If found in YAML, check if it has a value (not None or empty)
            if current is None or current == "":
                found_in_yaml = False
        except (KeyError, TypeError):
            found_in_yaml = False

        # Check if environment variable is available
        env_var_value = os.getenv(env_var_name)

        if found_in_yaml:
            print("✅ Found '{}' in YAML configuration".format(var_path))
        elif env_var_value:
            print(
                "ℹ️  Using environment variable '{}' for '{}'".format(
                    env_var_name, var_path
                )
            )
        else:
            missing_vars.append((var_path, env_var_name))

    if missing_vars:
        print("\n❌ Missing required variables:")
        for var_path, env_var_name in missing_vars:
            print(
                "  - '{}' not found in YAML and environment variable '{}' not set".format(
                    var_path, env_var_name
                )
            )
        print("\nPlease either:")
        print("1. Add the missing variables to notebook_vars.yml, or")
        print("2. Set the corresponding environment variables")
        sys.exit(1)

    print("✅ All required variables found.")


def main():
    """Main function."""
    # Define file paths
    script_dir = Path(__file__).parent
    template_file = script_dir / "notebooks" / "verify_setup.ipynb.j2"
    vars_file = script_dir / "notebook_vars.yml"
    output_file = script_dir / "notebooks" / "verify_setup.ipynb"

    print("🔄 Starting notebook generation...")
    print("📁 Template: {}".format(template_file))
    print("📁 Variables: {}".format(vars_file))
    print("📁 Output: {}".format(output_file))

    # Load variables
    print("\n📋 Loading variables...")
    variables = load_variables(vars_file)

    # Validate variables
    print("🔍 Validating variables...")
    validate_variables(variables)

    # Load template
    print("📄 Loading template...")
    template = load_template(template_file)

    # Generate notebook
    print("⚙️  Materializing notebook...")
    notebook = materialize_notebook(template, variables)

    # Create output directory if it doesn't exist
    output_file.parent.mkdir(parents=True, exist_ok=True)

    # Save notebook
    print("💾 Saving notebook...")
    save_notebook(notebook, output_file)

    print("\n🎉 Notebook generation completed successfully!")
    print(f"📖 You can now open '{output_file}' in VS Code or Jupyter.")


if __name__ == "__main__":
    main()
