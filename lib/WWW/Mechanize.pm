package WWW::Mechanize;

=head1 NAME

WWW::Mechanize - automate interaction with websites

=head1 VERSION

Version 0.57

    $Header: /cvsroot/www-mechanize/www-mechanize/lib/WWW/Mechanize.pm,v 1.51 2003/08/13 15:46:35 petdance Exp $

=cut

our $VERSION = "0.57";

=head1 SYNOPSIS

C<WWW::Mechanize>, or Mech for short, was designed to help you
automate interaction with a website. It supports performing a
sequence of page fetches including following links and submitting
forms. Each fetched page is parsed and its links and forms are
extracted. A link or a form can be selected, form fields can be
filled and the next page can be fetched. Mech also stores a history
of the URLs you've visited, which can be queried and revisited.

    use WWW::Mechanize;
    my $a = WWW::Mechanize->new();

    $a->get($url);

    $a->follow_link( n => 3 );
    $a->follow_link( text_regex => qr/download this/i );
    $a->follow_link( url => 'http://host.com/index.html' );

    $a->submit_form(
	form_number => 3,
	fields      => {
			username    => 'yourname',
			password    => 'dummy',
			}
    );

    $a->submit_form(
	form_name => 'search',
	fields    => { query  => 'pot of gold', },
	button    => 'Search Now'
    );


Mech is well suited for use in testing web applications.  If you
use one of the Test::* modules, you can check the fetched content
and use that as input to a test call.

    use Test::More;
    like( $a->content(), qr/$expected/, "Got expected content" );

Each page fetch stores its URL in a history stack which you can
traverse.

    $a->back();

If you want finer control over over your page fetching, you can use
these methods. C<follow_link> and C<submit_form> are just high
level wrappers around them.

    $a->follow($link);
    $a->find_link(n => $number);
    $a->form_number($number);
    $a->form_name($name);
    $a->field($name, $value);
    $a->set_fields( %field_values );
    $a->click($button);

L<WWW::Mechanize> is a proper subclass of L<LWP::UserAgent> and
you can also use any of L<LWP::UserAgent>'s methods.

    $a->add_header($name => $value);

=head1 IMPORTANT LINKS

=over 4

=item * L<http://search.cpan.org/dist/WWW-Mechanize/>

The CPAN documentation page for Mechanize.

=item * L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=WWW-Mechanize>

The RT queue for bugs & enhancements in Mechanize.  Click the "Report bug"
link if your bug isn't already reported.

=back

=head1 OTHER DOCUMENTATION

=over 4

=item * L<WWW::Mechanize::Examples>

A random array of examples submitted by users.

=item * L<http://www.perl.com/pub/a/2003/01/22/mechanize.html>

Chris Ball's article about using WWW::Mechanize for scraping TV listings.

=item * L<http://www.stonehenge.com/merlyn/LinuxMag/col47.html>

Randal Schwartz's article on scraping Yahoo News for images.  It's already
out of date: He manually walks the list of links hunting for matches,
which wouldn't have been necessary if the C<find_link()> method existed
at press time.

=item * L<http://www.perladvent.org/2002/16th/>

WWW::Mechanize on the Perl Advent Calendar, by Mark Fowler.

=back

=cut

use strict;
use warnings;

use HTTP::Request 1.30;
use LWP::UserAgent 2.003;
use HTML::Form 1.00;
use HTML::TokeParser;
use URI::URL;

our @ISA = qw( LWP::UserAgent );

our %headers;

=head1 Constructor and startup

=head2 C<< new() >>

Creates and returns a new WWW::Mechanize object, hereafter referred to as
the 'agent'.

    my $a = WWW::Mechanize->new()

The constructor for WWW::Mechanize overrides two of the parms to the
LWP::UserAgent constructor:

    agent => "WWW-Mechanize/#.##"
    cookie_jar => {}    # an empty, memory-only HTTP::Cookies object

You can override these overrides by passing parms to the constructor,
as in:

    my $a = WWW::Mechanize->new( agent=>"wonderbot 1.01" );

If you want none of the overhead of a cookie jar, or don't want your
bot accepting cookies, you have to explicitly disallow it, like so:

    my $a = WWW::Mechanize->new( cookie_jar => undef );

=cut

sub new {
    my $class = shift;

    my %default_parms = (
        agent       => "WWW-Mechanize/$VERSION",
        cookie_jar  => {},
    );

    my %parms = ( %default_parms, @_ );

    my $self = $class->SUPER::new( %parms );
    bless $self, $class;

    $self->{page_stack} = [];
    $self->{quiet} = 0;
    $self->env_proxy();
    push( @{$self->requests_redirectable}, 'POST' );

    $self->_reset_page;

    return $self;
}

=head2 C<< $a->agent_alias( $alias ) >>

Sets the user agent string to the expanded version from a table of actual user strings.
I<$alias> can be one of the following:

=over 4

=item * Windows IE 6

=item * Windows Mozilla

=item * Mac Safari

=item * Mac Mozilla

=item * Linux Mozilla

=item * Linux Konqueror

=back

then it will be replaced with a more interesting one.  For instance,

    $a->agent_alias( 'Windows IE 6' );

sets your User-Agent to

    Mozilla/4.0 (compatible; MSIE 6.0; Windows NT 5.1)

The list of valid aliases can be returned from C<known_agent_aliases()>.

=cut

my %known_agents = (
    'Windows IE 6'	=> 'Mozilla/4.0 (compatible; MSIE 6.0; Windows NT 5.1)',
    'Windows Mozilla'	=> 'Mozilla/5.0 (Windows; U; Windows NT 5.0; en-US; rv:1.4b) Gecko/20030516 Mozilla Firebird/0.6',
    'Mac Safari'	=> 'Mozilla/5.0 (Macintosh; U; PPC Mac OS X; en-us) AppleWebKit/85 (KHTML, like Gecko) Safari/85',
    'Mac Mozilla'	=> 'Mozilla/5.0 (Macintosh; U; PPC Mac OS X Mach-O; en-US; rv:1.4a) Gecko/20030401',
    'Linux Mozilla'	=> 'Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.4) Gecko/20030624',
    'Linux Konqueror'	=> 'Mozilla/5.0 (compatible; Konqueror/3; Linux)',
);

sub agent_alias {
    my $self = shift;
    my $alias = shift;

    if ( defined $known_agents{$alias} ) {
	return $self->agent( $known_agents{$alias} );
    } else {
	$self->_carp( qq{Unknown agent alias "$alias"} );
	return $self->agent();
    }
}

=head2 C<known_agent_aliases()>

Returns a list of all the agent aliases that Mech knows about.

=cut

sub known_agent_aliases {
    return sort keys %known_agents;
}

=head1 Page-fetching methods

=head2 C<< $a->get($url) >>

Given a URL/URI, fetches it.  Returns an C<HTTP::Response> object.
I<$url> can be a well-formed URL string, or a URI::* object.

The results are stored internally in the agent object, but you don't
know that.  Just use the accessors listed below.  Poking at the internals
is deprecated and subject to change in the future.

C<get()> is a well-behaved overloaded version of the method in
C<LWP::UserAgent>.  This lets you do things like

    $mech->get( $url, ":content_file"=>$tempfile );

and you can rest assured that the parms will get filtered down
appropriately.

=cut

sub get {
    my $self = shift;
    my $uri = shift;

    $uri = $self->{base}
	    ? URI->new_abs( $uri, $self->{base} )
	    : URI->new( $uri );

    return $self->SUPER::get( $uri->as_string, @_ );
}

=head2 C<< $a->reload() >>

Acts like the reload button in a browser: Reperforms the current request.

Returns undef if there's no current request, or the L<HTTP::Response>
object from the reload.

=cut

sub reload {
    my $self = shift;

    return unless $self->{req};

    return $self->request( $self->{req} );
}

=head2 C<< $a->back() >>

The equivalent of hitting the "back" button in a browser.  Returns to
the previous page.  Won't go back past the first page. (Really, what
would it do if it could?)

=cut

sub back {
    my $self = shift;
    $self->_pop_page_stack;
}

=head1 Link-following methods

=head2 C<< $a->follow_link(...) >>

Follows a specified link on the page.  You specify the match to be
found using the same parms that C<find_link()> uses.

Here some examples:

=over 4

=item * 3rd link called "download"

    $a->follow_link( text => "download", n => 3 );

=item * first link where the URL has "download" in it, regardless of case:

    $a->follow_link( url_regex => qr/download/i );

or

    $a->follow_link( url_regex => "(?i:download)" );

=item * 3rd link on the page

    $a->follow_link( n => 3 );

=back

Returns the result of the GET method (an HTTP::Response object) if
a link was found. If the page has no links, or the specified link
couldn't be found, returns undef.

This method is meant to replace C<< $a->follow() >> which should
not be used in future development.

=cut

sub follow_link {
    my $self = shift;
    my %parms = ( n=>1, @_ );

    if ( $parms{n} eq "all" ) {
	delete $parms{n};
	$self->_carp( qq{follow_link(n=>"all") is not valid} );
    }

    my $response;
    my $link = $self->find_link(%parms);
    if ( $link ) {
	$self->_push_page_stack();
	$response = $self->get( $link->url );
    }

    return $response;
}

=head1 Form field filling methods

=head2 C<< $a->form_number($number) >>

Selects the I<number>th form on the page as the target for subsequent
calls to field() and click().  Emits a warning and returns false if there
is no such form.  Forms are indexed from 1, so the first form is number 1,
not zero.

=cut

sub form_number {
    my ($self, $form) = @_;
    if ($self->{forms}->[$form-1]) {
        $self->{form} = $self->{forms}->[$form-1];
        return 1;
    } else {
	$self->_carp( "There is no form numbered $form" );
        return 0;
    }
}

=head2 C<< $a->form_name($name) >>

Selects a form by name.  If there is more than one form on the page with
that name, then the first one is used, and a warning is generated.

Note that this functionality requires libwww-perl 5.69 or higher.

=cut

sub form_name {
    my ($self, $form) = @_;

    my $temp;
    my @matches = grep {defined($temp = $_->attr('name')) and ($temp eq $form) } @{$self->{forms}};
    if ( @matches ) {
	require Carp;
        $self->{form} = $matches[0];
	$self->_carp( "There are ", scalar @matches, " forms named $form.  The first one was used." )
	    if @matches > 1;
        return 1;
    } else {
	$self->_carp( qq{ There is no form named "$form"} );
        return 0;
    }
}

=head2 C<< $a->field($name, $value, $number) >>

Given the name of a field, set its value to the value specified.  This
applies to the current form (as set by the C<form()> method or defaulting
to the first form on the page).

The optional C<$number> parameter is used to distinguish between two fields
with the same name.  The fields are numbered from 1.

=cut

sub field {
    my ($self, $name, $value, $number) = @_;
    $number ||= 1;

    my $form = $self->{form};
    if ($number > 1) {
        $form->find_input($name, undef, $number)->value($value);
    } else {
        $form->value($name => $value);
    }
}

=head2 C<< $a->set_fields( $name => $value ... ) >>

This method sets multiple fields of a form. It takes a list of field
name and value pairs. If there is more than one field with the same
name, the first one found is set. If you want to select which of the
duplicate field to set, use a value which is an anonymous array which
has the field value and its number as the 2 elements.

        # set the second foo field
        $a->set_fields( $name => [ 'foo', 2 ] ) ;

The fields are numbered from 1.

This applies to the current form (as set by the C<form()> method or
defaulting to the first form on the page).

=cut

sub set_fields {
    my ($self, %fields ) = @_;

    my $form = $self->{form};

    while( my ( $field, $value ) = each %fields ) {
        if ( ref $value eq 'ARRAY' ) {
            $form->find_input( $field, undef,
                         $value->[1])->value($value->[0] );
        } else {
            $form->value($field => $value);
        }
    }
}

=head2 C<< $a->tick($name, $value [, $set] ) >>

'Ticks' the first checkbox that has both the name and value assoicated
with it on the current form.  Dies if there is no named check box for
that value.  Passing in a false value as the third optional argument
will cause the checkbox to be unticked.

=cut

sub tick {
    my $self = shift;
    my $name = shift;
    my $value = shift;
    my $set = @_ ? shift : 1;  # default to 1 if not passed

    # loop though all the inputs
    my $input;
    my $index = 0;
    while($input = $self->current_form->find_input($name,"checkbox",$index)) {
	# Can't guarantee that the first element will be undef and the second
	# element will be the right name
	foreach my $val ($input->possible_values()) {
	    next unless defined $val;
	    if ($val eq $value) {
		$input->value($set ? $value : undef);
		return;
	    }
	}

	# move onto the next input
	$index++;
    } # while

    # got self far?  Didn't find anything
    $self->_carp( qq{No checkbox "$name" for value "$value" in form} );
} # tick()

=head2 C<< $a->untick($name, $value) >>

Causes the checkbox to be unticked.  Shorthand for
C<tick($name,$value,undef)>

=cut

sub untick {
    shift->tick(shift,shift,undef);
}

=head1 Form submission methods

=head2 C<< $a->click( $button [, $x, $y] ) >>

Has the effect of clicking a button on a form.  The first argument
is the name of the button to be clicked.  The second and third
arguments (optional) allow you to specify the (x,y) coordinates
of the click.

If there is only one button on the form, C<< $a->click() >> with
no arguments simply clicks that one button.

Returns an L<HTTP::Response> object.

=cut

sub click {
    my ($self, $button, $x, $y) = @_;
    for ($x, $y) { $_ = 1 unless defined; }
    $self->_push_page_stack();
    my $request = $self->{form}->click($button, $x, $y);
    return $self->request( $request );
}

=head2 C<< $a->submit() >>

Submits the page, without specifying a button to click.  Actually,
no button is clicked at all.

This used to be a synonym for C<< $a->click("submit") >>, but is no
longer so.

=cut

sub submit {
    my $self = shift;

    $self->_push_page_stack();
    my $request = $self->{form}->make_request;
    return $self->request( $request );
}

=head2 C<< $a->submit_form( ... ) >>

This method lets you select a form from the previously fetched page,
fill in its fields, and submit it. It combines the form_number/form_name,
set_fields and click methods into one higher level call. Its arguments
are a list of key/value pairs, all of which are optional.

=over 4

=item * form_number => n

Selects the I<n>th form (calls C<form_number()>).  If this parm is not
specified, the currently-selected form is used.

=item * form_name => name

Selects the form named I<name> (calls C<form_name()>)

=item * fields => fields

Sets the field values from the I<fields> hashref (calls C<set_fields()>)

=item * button => button

Clicks on button I<button> (calls C<click()>)

=item * x => x, y => y

Sets the x or y values for C<click()>

=back

If no form is selected, the first form found is used.

If I<button> is not passed, then the C<submit()> method is used instead.

Returns an HTTP::Response object.

=cut

sub submit_form {
    my( $self, %args ) = @_ ;

    for ( keys %args ) {
	if ( !/^(form_(number|name)|fields|button|x|y)$/ ) {
	    $self->_carp( qq{Unknown submit_form parameter "$_"} );
	}
    }

    if ( my $form_number = $args{'form_number'} ) {
	$self->form_number( $form_number ) ;
    }
    elsif ( my $form_name = $args{'form_name'} ) {
        $self->form_name( $form_name ) ;
    }

    if ( my $fields = $args{'fields'} ) {
        if ( ref $fields eq 'HASH' ) {
	    $self->set_fields( %{$fields} ) ;
        } # TODO: What if it's not a hash?  We just ignore it silently?
    }

    my $response;
    if ( $args{button} ) {
	$response = $self->click( $args{button}, $args{x} || 0, $args{y} || 0 );
    } else {
	$response = $self->submit();
    }

    return $response;
}

=head1 Status methods

=head2 C<< $a->success() >>

Returns a boolean telling whether the last request was successful.
If there hasn't been an operation yet, returns false.

This is a convenience function that wraps C<< $a->res->is_success >>.

=cut

sub success {
    my $self = shift;

    return $self->res && $self->res->is_success;
}


=head2 C<< $a->uri() >>

Returns the current URI.

=head2 C<< $a->response() >> or C<< $a->res() >>

Return the current response as an C<HTTP::Response> object.

Synonym for C<< $a->response() >>

=head2 C<< $a->status() >>

Returns the HTTP status code of the response.

=head2 C<< $a->ct() >>

Returns the content type of the response.

=head2 C<< $a->base() >>

Returns the base URI for the current response

=head2 C<< $a->content() >>

Returns the content for the response

=head2 C<< $a->forms() >>

When called in a list context, returns a list of the forms found in
the last fetched page. In a scalar context, returns a reference to
an array with those forms. The forms returned are all C<HTML::Form>
objects.

=head2 C<< $a->current_form() >>

Returns the current form as an C<HTML::Form> object.  I'd call this
C<form()> except that C<form()> already exists and sets the current_form.

=head2 C<< $a->links() >>

When called in a list context, returns a list of the links found in
the last fetched page. In a scalar context it returns a reference to
an array with those links. The links returned are all references to
two element arrays which contain the URL and the text for each link.

=head2 C<< $a->is_html() >>

Returns true/false on whether our content is HTML, according to the
HTTP headers.

=cut

sub uri {           my $self = shift; return $self->{uri}; }
sub res {           my $self = shift; return $self->{res}; }
sub response {      my $self = shift; return $self->{res}; }
sub status {        my $self = shift; return $self->{status}; }
sub ct {            my $self = shift; return $self->{ct}; }
sub base {          my $self = shift; return $self->{base}; }
sub content {       my $self = shift; return $self->{content}; }
sub current_form {  my $self = shift; return $self->{form}; }
sub is_html {       my $self = shift; return defined $self->{ct} && ($self->{ct} eq "text/html"); }

sub links {
    my $self = shift ;
    return @{$self->{links}} if wantarray;
    return $self->{links};
}

sub forms {
    my $self = shift ;
    return @{$self->{forms}} if wantarray;
    return $self->{forms};
}


=head2 C<< $a->title() >>

Returns the contents of the C<< <TITLE> >> tag, as parsed by
HTML::HeadParser.  Returns undef if the content is not HTML.

=cut

sub title {
    my $self = shift;
    return unless $self->is_html;

    require HTML::HeadParser;
    my $p = HTML::HeadParser->new;
    $p->parse($self->content);
    return $p->header('Title');
}

=head1 Content-handling methods

=head2 C<< $a->find_link() >>

This method finds a link in the currently fetched page. It returns a
L<WWW::Mechanize::Link> object which describes the link.  (You'll probably
be most interested in the C<url()> property.)  If it fails to find a
link it returns undef.

You can take the URL part and pass it to the C<get()> method.  If that's
your plan, you might as well use the C<follow_link()> method directly,
since it does the C<get()> for you automatically.

Note that C<< <FRAME SRC="..."> >> tags are parsed out of the the HTML
and treated as links so this method works with them.

You can select which link to find by passing in one or more of these
key/value pairs:

=over 4

=item * text => string

Matches the text of the link against I<string>, which must be an
exact match.

To select a link with text that is exactly "download", use

    $a->find_link( text => "download" );

=item * text_regex => regex

Matches the text of the link against I<regex>.

To select a link with text that has "download" anywhere in it,
regardless of case, use

    $a->find_link( text_regex => qr/download/i );

=item * url => string

Matches the URL of the link against I<string>, which must be an
exact match.  This is similar to the C<text> parm.

=item * url_regex => regex

Matches the URL of the link against I<regex>.  This is similar to
the C<text_regex> parm.

=item * n => I<number>

Matches against the I<n>th link.

The C<n> parms can be combined with the C<text*> or C<url*> parms
as a numeric modifier.  For example, 
C<< text => "download", n => 3 >> finds the 3rd link which has the
exact text "download".

=back

If C<n> is not specified, it defaults to 1.  Therefore, if you don't
specify any parms, this method defaults to finding the first link on the
page.

Note that you can specify multiple text or URL parameters, which
will be ANDed together.  For example, to find the first link with
text of "News" and with "cnn.com" in the URL, use:

    $a->find_link( text => "News", url_regex => qr/cnn\.com/ );

=head2 C<< $a->find_link() >>: link format

The return value is a reference to an array containing
a L<WWW::Mechanize::Link> object for every link in 
C<< $self->{content} >>.  

The links come from the following:

=over 4

=item C<< <A HREF=...> >>

=item C<< <AREA HREF=...> >>

=item C<< <FRAME SRC=...> >>

=item C<< <IFRAME SRC=...> >>

=back

The array elements are:

=over 4

=item [0]: contents of the link

=item [1]: text enclosed by the tag

=item [2]: the contents of the C<NAME> attribute

=back

=cut

sub find_link {
    my $self = shift;
    my %parms = ( n=>1, @_ );

    my @links = @{$self->{links}};

    return unless @links ;

    my $wantall = ( $parms{n} eq "all" );

    for ( keys %parms ) {
	if ( !/^(n|(text|url)(_regex)?)$/ ) {
	    $self->_carp( qq{Unknown link-finding parameter "$_"} );
	}
    }

    my @conditions;
    push @conditions, q/ $_[0]->[0] eq $parms{url} /	    if defined $parms{url};
    push @conditions, q/ $_[0]->[0] =~ $parms{url_regex} /  if defined $parms{url_regex};
    push @conditions, q/ defined($_[0]->[1]) and $_[0]->[1] eq $parms{text} /	    if defined $parms{text};
    push @conditions, q/ defined($_[0]->[1]) and $_[0]->[1] =~ $parms{text_regex} / if defined $parms{text_regex};

    my $matchfunc;
    if ( @conditions ) {
	local $" = " && ";
	$matchfunc = eval "sub { @conditions }";
    } else {
	$matchfunc = sub{1};
    }

    my $nmatches = 0;
    my @matches;
    for my $link ( @links ) {
	if ( $matchfunc->($link) ) {
	    if ( $wantall ) {
		push( @matches, $link );
	    } else {
		++$nmatches;
		return $link if $nmatches >= $parms{n};
	    }
	}
    } # for @links

    if ( $wantall ) {
	return @matches if wantarray;
	return \@matches;
    }

    return;
} # find_link

=head2 C<< $a->find_all_links( ... ) >>

Returns all the links on the current page that match the criteria.
The method for specifying link criteria is the same as in
C<find_link()>.  Each of the links returned is in the same format
as in C<find_link()>.

In list context, C<find_all_links()> returns a list of the links.
Otherwise, it returns a reference to the list of links.

C<find_all_links()> with no parameters returns all links in the
page.

=cut

sub find_all_links {
    my $self = shift;
    return $self->find_link( @_, n=>'all' );
}


=head1 Miscellaneous methods

=head2 C<< $a->add_header(name => $value) >>

Sets a header for the WWW::Mechanize agent to use every time it gets
a webpage.  This is B<NOT> stored in the agent object (because if it
were, it would disappear if you went back() past where you'd set it)
but in the hash variable C<%WWW::Mechanize::headers>, which is a hash of
all headers to be set.  You can manipulate this directly if you want to;
the add_header() method is just provided as a convenience function for
the most common case of adding a header.

=cut

sub add_header {
    my ($self, $name, $value) = @_;
    $WWW::Mechanize::headers{$name} = $value;
}

=head2 C<< $a->quiet(true/false) >>

Allows you to suppress warnings to the screen.

    $a->quiet(0); # turns on warnings (the default)
    $a->quiet(1); # turns off warnings
    $a->quiet();  # returns the current quietness status

=cut

sub quiet {
    my $self = shift;

    $self->{quiet} = $_[0] if @_;

    return $self->{quiet};
}

=head1 Overridden C<LWP::UserAgent> methods

=head2 C<< $a->redirect_ok() >>

An overloaded version of C<redirect_ok()> in L<LWP::UserAgent>.
This method is used to determine whether a redirection in the request
should be followed.

It's also used to keep track of the last URI redirected to. Also
if the redirection was from a POST, it changes the HTTP method
to GET. This does not conform with the RFCs, but it is how many
browser user agent implementations behave. As we are trying to model
them, we must unfortunately mimic their erroneous reaction. See
L<http://www.w3.org/Protocols/rfc2616/rfc2616-sec10.html#sec10.3> for
details on correct behaviour.

=cut

sub redirect_ok {
    my $self = shift;
    my $prospective_request = shift;

    my $ok = $self->SUPER::redirect_ok( $prospective_request );
    if ( $ok ) {
	$self->{redirected_uri} = $prospective_request->uri;

	# Mimic erroneous browser behaviour by changing the method.
	$prospective_request->method("GET") if $prospective_request->method eq "POST";
    }

    return $ok;
};


=head2 C<< $a->request( $request [, $arg [, $size]]) >>

Overloaded version of C<request()> in L<LWP::UserAgent>.  Performs
the actual request.  Normally, if you're using WWW::Mechanize, it'd
because you don't want to deal with this level of stuff anyway.

Note that C<$request> will be modified.

Returns an L<HTTP::Response> object.

=cut

sub request {
    my $self = shift;
    my $request = shift;

    $request->header( Referer => $self->{last_uri} ) if $self->{last_uri};
    while ( my($key,$value) = each %WWW::Mechanize::headers ) {
        $request->header( $key => $value );
    }
    $self->{req} = $request;
    $self->{redirected_uri} = $request->uri->as_string;
    $self->{res} = $self->SUPER::request( $request, @_ );

    # These internal hash elements should be dropped in favor of
    # the accessors soon. -- 1/19/03
    $self->{status}  = $self->{res}->code;
    $self->{base}    = $self->{res}->base;
    $self->{ct}      = $self->{res}->content_type || "";
    $self->{content} = $self->{res}->content;
    if ( $self->{res}->is_success ) {
	$self->{uri} = $self->{redirected_uri};
	$self->{last_uri} = $self->{uri};
    }

    $self->_reset_page();
    if ( $self->is_html ) {
        $self->{forms} = [ HTML::Form->parse($self->{content}, $self->{res}->base) ];
        $self->{form}  = $self->{forms}->[0];
        $self->_extract_links();
    }

    return $self->{res};
}

=head1 Deprecated methods

This methods have been replaced by more flexible and precise methods.
Please use them instead.

=head2 C<< $a->follow($string|$num) >>

B<DEPRECATED> in favor of C<follow_link()>, which provides more
flexibility.

Follow a link.  If you provide a string, the first link whose text
matches that string will be followed.  If you provide a number, it
will be the I<$num>th link on the page.  Note that the links are
0-based.

Returns true if the link was found on the page or undef otherwise.

=cut

sub follow {
    my ($self, $link) = @_;
    my @links = @{$self->{links}};
    my $thislink;
    if ( $link =~ /^\d+$/ ) { # is a number?
        if ($link <= $#links) {
            $thislink = $links[$link];
        } else {
	    $self->_carp( "Link number $link is greater than maximum link $#links on this page ($self->{uri})" );
            return;
        }
    } else {                        # user provided a regexp
        LINK: foreach my $l (@links) {
            if ($l->[1] =~ /$link/) {
                $thislink = $l;     # grab first match
                last LINK;
            }
        }
        unless ($thislink) {
	    $self->_carp( "Can't find any link matching $link on this page ($self->{uri})" );
            return;
        }
    }

    $thislink = $thislink->[0];     # we just want the URL, not the text

    $self->_push_page_stack();
    $self->get( $thislink );

    return 1;
}

=head2 C<< $a->form($number|$name) >>

B<DEPRECATED> in favor of C<form_name()> or C<form_number()>.

Selects a form by number or name, depending on if it gets passed an
all-numeric string or not.  This means that if you have a form name
that's all digits, this method will not do the right thing.

=cut

sub form {
    my $self = shift;
    my $arg = shift;

    return $arg =~ /^\d+$/ ? $self->form_number($arg) : $self->form_name($arg);
}

=head1 Internal-only methods

These methods are only used internally.  You probably don't need to 
know about them.

=head2 C<< $a->_reset_page() >>

Resets the internal fields that track page parsed stuff.

=cut

sub _reset_page {
    my $self = shift;

    $self->{links} = [];
    delete $self->{title};
    $self->{forms} = [];
    delete $self->{form};
    
    return;
}

=head2 C<< $a->_extract_links() >>

Extracts links from the content of a webpage, and populates the C<{links}>
property with L<WWW::Mechanize::Link> objects.

=cut

my %urltags = (
    a => "href",
    area => "href",
    frame => "src",
    iframe => "src",
);

sub _extract_links {
    require WWW::Mechanize::Link;

    my $self = shift;

    my $p = HTML::TokeParser->new(\$self->{content});
    
    $self->{links} = [];

    while (my $token = $p->get_tag( keys %urltags )) {
        my $tag = $token->[0];
        my $url = $token->[1]{$urltags{$tag}};
        next unless defined $url;   # probably just a name link or <AREA NOHREF...>

        my $text;
	my $name;
	if ( $tag eq "a" ) {
	    $text = $p->get_trimmed_text("/$tag");
	    $text = "" unless defined $text;
	}
	if ( $tag ne "area" ) {
	    $name = $token->[1]{name};
	}

        push( @{$self->{links}}, WWW::Mechanize::Link->new( $url, $text, $name, $tag ) );
    }

    # Old extract_links() returned a value.  Carp if someone expects
    # this version to return something.
    if ( defined wantarray ) {
	my $func = (caller(0))[3];
	$self->_carp( "$func does not return a useful value" );
    }

    return;
}

=head2 C<< $a->_push_page_stack() >> and C<< $a->_pop_page_stack() >>

The agent keeps a stack of visited pages, which it can pop when it needs
to go BACK and so on.  

The current page needs to be pushed onto the stack before we get a new
page, and the stack needs to be popped when BACK occurs.

Neither of these take any arguments, they just operate on the $a
object.

=cut

sub _push_page_stack {
    my $self = shift;

    my $save_stack = $self->{page_stack};
    $self->{page_stack} = [];

    push( @$save_stack, $self->clone );

    $self->{page_stack} = $save_stack;

    return 1;
}

sub _pop_page_stack {
    my $self = shift;

    if (@{$self->{page_stack}}) {
        my $popped = pop @{$self->{page_stack}};

        # eliminate everything in self
        foreach my $key ( keys %$self ) {
            delete $self->{ $key }              unless $key eq 'page_stack';
        }

        # make self just like the popped object
        foreach my $key ( keys %$popped ) {
            $self->{ $key } = $popped->{ $key } unless $key eq 'page_stack';
        }
    }

    return 1;
}

sub _carp {
    my $self = shift;

    if ( !$self->quiet ) {
	eval "require Carp";
	if ( $@ ) {
	    warn @_;
	} else {
	    &Carp::carp; # pass thru
	}
    }
    return;
}


=head1 FAQ

=head2 Why don't https:// URLs work?

You probably don't have L<IO::Socket::SSL> installed.

=head2 I tried to [such-and-such] and I got this weird error.

Are you checking your errors?

Are you sure?

Are you checking that your action succeeded after every action?

Are you sure?

For example, if you try this:

    $mech->get( "http://my.site.com" );
    $mech->follow_link( "foo" );

and the C<get> call fails for some reason, then the Mech internals
will be unusable for the C<follow_link> and you'll get a weird
error.  You B<must>, after every action that GETs or POSTs a page,
check that Mech succeeded, or all bets are off.

    $mech->get( "http://my.site.com" );
    die "Can't even get the home page: ", $mech->response->status_line
	unless $mech->success;

    $mech->follow_link( "foo" );
    die "Foo link failed: ", $mech->response->status_line
	unless $mech->success;

I guarantee you this will be the very first thing that I ask if
you mail me about a problem with Mech.

=head2 Can I do [such-and-such] with WWW::Mechanize?

If it's possible with LWP::UserAgent, then yes.  WWW::Mechanize is
a subclass of L<LWP::UserAgent>, so all the wondrous magic of that
class is inherited.

=head2 How do I use WWW::Mechanize through a proxy server?

See the docs in LWP::UserAgent on how to use the proxy.  Short
version:

    $a->proxy(['http', 'ftp'], 'http://proxy.example.com:8000/');

or get the specs from the environment:

    $a->env_proxy();

    # Environment set like so:
    gopher_proxy=http://proxy.my.place/
    wais_proxy=http://proxy.my.place/
    no_proxy="localhost,my.domain"
    export gopher_proxy wais_proxy no_proxy

=head1 See Also

See also L<WWW::Mechanize::Examples> for sample code.
L<WWW::Mechanize::FormFiller> and L<WWW::Mechanize::Shell> are add-ons
that turn Mechanize into more of a scripting tool.

=head1 Requests & Bugs

Please report any requests, suggestions or (gasp!) bugs via the
excellent RT bug-tracking system at http://rt.cpan.org/, or email to
bug-WWW-Mechanize@rt.cpan.org.  This makes it much easier for me to
track things.

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=WWW-Mechanize> is the RT queue
for Mechanize.  Please check to see if your bug has already been reported.

=head1 Author

Copyright 2003 Andy Lester <andy@petdance.com>

Released under the Artistic License.  Based on Kirrily Robert's excellent
L<WWW::Automate> package.

=cut

1;
