class Contact
  include Mongoid::Document
  before_validation :format_phone_number
  before_save :update_international

  # I'd normally set this up to allow a contact to have multiple email addresses or phone numbers
  # but given the scope of the assignment it doesn't seem necessary.
  field :first_name, type: String
  field :last_name, type: String
  field :email_address, type: String
  field :phone_number, type: String
  field :company_name, type: String
  field :international_number, type: Boolean

  belongs_to :user
  validates :user, presence: true

  validates :email_address, format: { with: /\A[^@\s]+@[-a-z0-9]+\.[a-z]{2,}/i,
    message: 'Email address must be a valid format' , allow_blank: true }

  # Uses the Phonelib gem and Googles libphonenumber to validate phone numbers for things like
  # real country/area/carrier codes, international formatting
  # Setting allow_blank to true so we can store contacts even if the user doesn't have a number
  validates :phone_number, phone: { allow_blank: true , message: 'Phone number must be valid' }

  # Creating a custom validation method to ensure at least first-, last-, or company name are present
  # and one of either phone_number or email_address
  validate do |contact|
    contact.any_value_present? attributes: [:first_name, :last_name, :company_name]
    contact.any_value_present? attributes: [:phone_number, :email_address]
  end

  def any_value_present?(attributes: [])
    if attributes.all? { |attr| self[attr].blank? }
      errors.add :base, "At least one of #{attributes.join(", ")} must be present"
    end
  end

  # Because I'm not allowing multiple email addresses or phone numbers per contact I am not going to force uniqueness
  # except when all 5 fields are identical to allow a user to have the same contact listed multiple times
  # with differing numbers, emails, or companies. Setting up an index to enforce this at the db layer to prevent
  # race conditions when running on multiple workers
  index( { first_name: 1, last_name: 1, email_address: 1,
    phone_number: 1, company_name: 1, user_id: 1}, { unique: true, name: 'contact_index' })
  validates :user, uniqueness: {scope: [:first_name, :last_name, :email_address, :phone_number, :company_name],
    message: 'A duplicate entry for this contact already exists'}

  # Define a scope so we can easily limit to only contacts owned by the user in our controllers
  scope :contacts_for, ->(user = nil) { where(user: user) }

  class ContactImportError < StandardError
    INVALID_FILE_TYPE = 'Only .tsv files can be imported'
    FILE_READ_ERROR = 'Something went wrong while processing this file'
  end

  # Takes a File IO object and attempts to import each line as a contact for provided user.
  # Returns the list of rows that weren't imported and their associated errors
  def self.import_contacts(user, file_io)
    errors = []

    # Check if the file has the right extension
    raise ContactImportError.new(ContactImportError::INVALID_FILE_TYPE) unless /\.tsv$/ =~ file_io.path

    begin
      # Iterate over each line but drop the header
      file_io.readlines.drop(1).each_with_index do |line, index|

        begin
          # Split each line by tabs
          contact_params = line.split("\t")
          c = Contact.new(first_name: contact_params[0], last_name: contact_params[1], email_address: contact_params[2],
            phone_number: contact_params[3], company_name: contact_params[4], user: user)

          # Save if valid, otherwise add the row to the list of errors
          if c.valid?
            c.save
          else
            errors << { row: index+1, errors: c.errors.messages.values.flatten, data: contact_params.join(", ")}
          end
        # Rescue at the row level in case we can recover and continue importing other contacts
        rescue Mongo::Error::OperationFailure
          # Duplicate entry error
          errors << { row: index+1, errors: ['A duplicate entry for this contact already exists'], data: contact_params.join(", ")}
        rescue
          # Some other unexpected error, most likely to do with formatting
          errors << { row: index+1, errors: ['An unexpected error has occurred while processing this line']}
        end
      end

      errors

    rescue
      # If something breaks while processing the file outside of individual rows
      raise ContactImportError.new(ContactImportError::FILE_READ_ERROR)
    end
  end

  private
  # A before save callback for setting a field in the DB if the phone number is considered international
  # Sets it to false if the number is blank or nil or
  def update_international
    if self.phone_number.present?
      self.international_number = Phonelib.default_country != Phonelib.parse(self.phone_number).country
    else
      self.international_number = false
    end
    # Always need to return true so that the rest of the callback chain is called
    return true
  end

  # A before save callback for normalizing the phonenumber into Phonelib full_international format
  def format_phone_number
    self.phone_number = Phonelib.parse(self.phone_number).full_international
  end
end
