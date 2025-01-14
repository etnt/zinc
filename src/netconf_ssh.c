#include <libssh/libssh.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NETCONF_HELLO \
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" \
    "<hello xmlns=\"urn:ietf:params:xml:ns:netconf:base:1.0\">\n" \
    "  <capabilities>\n" \
    "    <capability>urn:ietf:params:netconf:base:1.0</capability>\n" \
    "  </capabilities>\n" \
    "</hello>\n"

void error_exit(const char *message, ssh_session session) {
    fprintf(stderr, "%s: %s\n", message, ssh_get_error(session));
    if (session) ssh_free(session);
    exit(EXIT_FAILURE);
}

int main() {
    ssh_session session;
    ssh_channel channel;
    int rc;

    // Initialize SSH session
    session = ssh_new();
    if (session == NULL) {
        fprintf(stderr, "Failed to initialize SSH session.\n");
        exit(EXIT_FAILURE);
    }

    // Set connection parameters
    ssh_options_set(session, SSH_OPTIONS_HOST, "10.147.40.55"); // Replace with your server address
    ssh_options_set(session, SSH_OPTIONS_PORT_STR, "2022"); // Replace with your server port
    ssh_options_set(session, SSH_OPTIONS_USER, "admin"); // Replace with your username

    // Connect to the server
    rc = ssh_connect(session);
    if (rc != SSH_OK) {
        error_exit("Error connecting to server", session);
    }

    // Authenticate
    rc = ssh_userauth_password(session, NULL, "admin"); // Replace with your password
    if (rc != SSH_AUTH_SUCCESS) {
        error_exit("Authentication failed", session);
    }

    // Open a new channel
    channel = ssh_channel_new(session);
    if (channel == NULL) {
        error_exit("Failed to open channel", session);
    }

    rc = ssh_channel_open_session(channel);
    if (rc != SSH_OK) {
        error_exit("Failed to open channel session", session);
    }

    // Start a NETCONF subsystem
    rc = ssh_channel_request_subsystem(channel, "netconf");
    if (rc != SSH_OK) {
        error_exit("Failed to start NETCONF subsystem", session);
    }

    // Send the NETCONF HELLO message
    rc = ssh_channel_write(channel, NETCONF_HELLO, strlen(NETCONF_HELLO));
    if (rc < 0) {
        error_exit("Failed to send NETCONF HELLO message", session);
    }

    // Read the response from the server
    char buffer[4096];
    memset(buffer, 0, sizeof(buffer));
    rc = ssh_channel_read(channel, buffer, sizeof(buffer) - 1, 0); // Blocking read
    if (rc < 0) {
        error_exit("Failed to read response from server", session);
    }

    // Print the server response
    printf("NETCONF Server Response:\n%s\n", buffer);

    // Clean up and close
    ssh_channel_close(channel);
    ssh_channel_free(channel);
    ssh_disconnect(session);
    ssh_free(session);

    return 0;
}
