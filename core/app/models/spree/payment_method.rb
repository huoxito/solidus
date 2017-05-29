module Spree
  # A base class which is used for implementing payment methods.
  #
  # See https://github.com/solidusio/solidus_gateway/ for
  # offically supported payment method implementations.
  #
  # Uses STI (single table inheritance) to store all implemented payment methods
  # in one table (+spree_payment_methods+).
  #
  # This class is not meant to be instantiated. Please create instances of concrete payment methods.
  #
  class PaymentMethod < Spree::Base
    preference :server, :string, default: 'test'
    preference :test_mode, :boolean, default: true

    acts_as_paranoid
    acts_as_list
    DISPLAY = [:both, :front_end, :back_end]

    validates :name, :type, presence: true

    has_many :payments, class_name: "Spree::Payment", inverse_of: :payment_method
    has_many :credit_cards, class_name: "Spree::CreditCard"
    has_many :store_payment_methods, inverse_of: :payment_method
    has_many :stores, through: :store_payment_methods

    scope :ordered_by_position, -> { order(:position) }
    scope :active, -> { where(active: true) }
    scope :available_to_users, -> { where(available_to_users: true) }
    scope :available_to_admin, -> { where(available_to_admin: true) }
    scope :available_to_store, ->(store) do
      raise ArgumentError, "You must provide a store" if store.nil?
      store.payment_methods.empty? ? all : where(id: store.payment_method_ids)
    end

    delegate :authorize, :purchase, :capture, :void, :credit, to: :gateway

    include Spree::Preferences::StaticallyConfigurable

    class << self
      def providers
        Spree::Deprecation.warn 'Spree::PaymentMethod.providers is deprecated and will be deleted in Solidus 3.0. ' \
          'Please use Rails.application.config.spree.payment_methods instead'
        Rails.application.config.spree.payment_methods
      end

      def available(display_on = nil, store: nil)
        Spree::Deprecation.warn "Spree::PaymentMethod.available is deprecated."\
          "Please use .active, .available_to_users, and .available_to_admin scopes instead."\
          "For payment methods associated with a specific store, use Spree::PaymentMethod.available_to_store(your_store)"\
          " as the base applying any further filtering"

        display_on = display_on.to_s

        available_payment_methods =
          case display_on
          when 'front_end'
            active.available_to_users
          when 'back_end'
            active.available_to_admin
          else
            active.available_to_users.available_to_admin
          end
        available_payment_methods.select do |p|
          store.nil? || store.payment_methods.empty? || store.payment_methods.include?(p)
        end
      end

      def active?
        where(type: to_s, active: true).count > 0
      end

      def find_with_destroyed(*args)
        unscoped { find(*args) }
      end
    end

    # Represents the gateway of this payment method
    #
    # The gateway is responsible for communicating with the providers API.
    #
    # It implements methods for:
    #
    #     - authorize
    #     - purchase
    #     - capture
    #     - void
    #     - credit
    #
    def gateway
      gateway_options = options
      gateway_options.delete :login if gateway_options.key?(:login) && gateway_options[:login].nil?
      if gateway_options[:server]
        ActiveMerchant::Billing::Base.mode = gateway_options[:server].to_sym
      end
      @gateway ||= gateway_class.new(gateway_options)
    end
    alias_method :provider, :gateway
    deprecate provider: :gateway, deprecator: Spree::Deprecation

    # Represents all preferences as a Hash
    #
    # Each preference is a key holding the value(s) and gets passed to the gateway via +gateway_options+
    #
    # @return Hash
    def options
      preferences.to_hash
    end

    # The class that will store payment sources (re)usable with this payment method
    #
    # Used by Spree::Payment as source (e.g. Spree::CreditCard in the case of a credit card payment method).
    #
    # Returning nil means the payment method doesn't support storing sources (e.g. Spree::PaymentMethod::Check)
    def payment_source_class
      raise ::NotImplementedError, "You must implement payment_source_class method for #{self.class}."
    end

    # @deprecated Use {#available_to_users=} and {#available_to_admin=} instead
    def display_on=(value)
      Spree::Deprecation.warn "Spree::PaymentMethod#display_on= is deprecated."\
        "Please use #available_to_users= and #available_to_admin= instead."
      self.available_to_users = value.blank? || value == 'front_end'
      self.available_to_admin = value.blank? || value == 'back_end'
    end

    # @deprecated Use {#available_to_users} and {#available_to_admin} instead
    def display_on
      Spree::Deprecation.warn "Spree::PaymentMethod#display_on is deprecated."\
        "Please use #available_to_users and #available_to_admin instead."
      if available_to_users? && available_to_admin?
        ''
      elsif available_to_users?
        'front_end'
      elsif available_to_admin?
        'back_end'
      else
        'none'
      end
    end

    # Used as partial name for your payment method
    #
    # Currently your payment method needs to provide these partials:
    #
    #     1. app/views/spree/checkout/payment/_{method_type}.html.erb
    #     The form your customer enters the payment information in during checkout
    #
    #     2. app/views/spree/checkout/existing_payment/_{method_type}.html.erb
    #     The payment information of your customers reusable sources during checkout
    #
    #     3. app/views/spree/admin/payments/source_forms/_{method_type}.html.erb
    #     The form an admin enters payment information in when creating orders in the backend
    #
    #     4. app/views/spree/admin/payments/source_views/_{method_type}.html.erb
    #     The view that represents your payment method on orders in the backend
    #
    def method_type
      type.demodulize.downcase
    end

    def payment_profiles_supported?
      false
    end

    def source_required?
      true
    end

    # Custom gateways should redefine this method. See Gateway implementation
    # as an example
    def reusable_sources(_order)
      []
    end

    def auto_capture?
      auto_capture.nil? ? Spree::Config[:auto_capture] : auto_capture
    end

    # Check if given source is supported by this payment method
    #
    # Please implement validation logic in your payment method implementation
    #
    # @see Spree::PaymentMethod::CreditCard#supports?
    def supports?(_source)
      true
    end

    def cancel(_response)
      raise ::NotImplementedError, 'You must implement cancel method for this payment method.'
    end

    def store_credit?
      is_a? Spree::PaymentMethod::StoreCredit
    end

    protected

    # Represents the gateway class of this payment method
    #
    def gateway_class
      if respond_to? :provider_class
        Spree::Deprecation.warn \
          "provider_class is deprecated and will be removed from Solidus 3.0 " \
          "(use gateway_class instead)"
        public_send :provider_class
      else
        raise ::NotImplementedError, "You must implement gateway_class method for #{self.class}."
      end
    end
    deprecate provider_class: :gateway_class, deprecator: Spree::Deprecation
  end
end
