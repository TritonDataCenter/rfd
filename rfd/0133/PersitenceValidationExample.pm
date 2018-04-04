package PersistenceValidationExample;

# Name of the validation, mapped to row in `validation` table
my $NAME = "bios_version_example_persistence";

# Version of the validation
my $VERSION = 1;

# Textual descripton of the validation
my $DESCRIPTION = q(
Example of a persistence validation to persist the device BIOS version
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

# A normal validation defines 'validate', a persistence validation defines
# 'persist' and is passed a data access object with methods to write data to
# the database
sub persist {
    my ( $input_data, $hardware_product, $data_access_object ) = @_;

    # This method abstracts the details of storing the bios version. It will
    # write the bios version to the correct table for the device under
    # validation. A fake object may be used for testing this validation.
    $data_access_object->store_bios_version( $input_data->{bios_version} );

    # Additional persistence methods may continue ...

}

1;
