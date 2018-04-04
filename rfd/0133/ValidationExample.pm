package ValidationExample;

# Name of the validation, mapped to row in `validation` table
my $NAME = "bios_version_example_validation";

# Version of the validation
my $VERSION = 1;

# Textual descripton of the validation
my $DESCRIPTION = q(
Example of a validation code module validating the BIOS version
);

# A schema may be defined to verify the input data before validation, or...
my $INPUT_SCHEMA =
  { bios_version => { type => string, minLength => 3, maxLength => 10 } };

# alternatively, a function can be defined to check the inputs.
sub check_input {
    my ($input_data) = @_;

    my $bios_version = $input_data->{bios_version};

    die "Input needs key 'bios_version'" unless $bios_version;

    die "'bios_version' must be a string" if ref($bios_version);

    die "'bios_version' string must be between 5 and 20 characters"
      unless length($bios_version) >= 3 && length($bios_version) <= 10;

    return 1;
}

# The validation function. It provides the schema-checked input data, a object
# storing hardware product specifications , and a mediator object, which
# provides methods to access stored data and methods to register validation
# results
sub validate {
    my ( $input_data, $hardware_product, $mediator ) = @_;

    # Get product names defined in the database
    my $expected_bios_version = $hardware_product->bios_version;

    # Raises an exception to halt further execution if there's no bios version
    # defined for the hardware product
    $mediator->error(
        "Hardware product doesn't define a BIOS version to validate against!")
      unless $expected_bios_version;

    if ( $expected_bios_version eq $parameters->{bios_version} ) {
        # Registers a success validation result
        $mediator->success(
            expected => $expected_bios_version
              got    => $parameters->{bios_version},
            component_type => 'bios_version'
        );
    }
    else {
        # Registers a failed validation result
        $mediator->fail(
            expected => $expected_bios_version
              got    => $parameters->{bios_version},
            component_type => 'bios_version'
        );
    }

    # additional validations may continue on...
}

1;
