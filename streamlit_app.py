# app.py

# --- Core Dependencies ---
import streamlit as st
import pandas as pd
import requests
import html
import re
import time
import io
from bs4 import BeautifulSoup
from urllib.parse import urljoin, urlparse, urlencode, parse_qs
from concurrent.futures import ThreadPoolExecutor, as_completed

# --- Installation & Setup Instructions ---
# Create a virtual environment and install the required packages.
#
# bash
# python -m venv venv
# source venv/bin/activate  # On Windows, use `venv\Scripts\activate`
# pip install -r requirements.txt
#
# --- requirements.txt ---
# streamlit
# pandas
# requests
# beautifulsoup4
# fake-useragent
# googlesearch-python
# openpyxl  # For Excel file support

# --- Import Helper Libraries ---
try:
    from googlesearch import search
except ImportError:
    st.error("The `googlesearch-python` library is not installed. Please run: `pip install googlesearch-python`")
    st.stop()

try:
    from fake_useragent import UserAgent
    ua = UserAgent()
except Exception:
    st.warning("`fake-useragent` library not found or failed. Using a fallback User-Agent. Run: `pip install fake-useragent` for better results.")
    ua = None

# --- Application Constants ---
WHATSAPP_DOMAIN = "https://chat.whatsapp.com/"
MAX_VALIDATION_WORKERS = 10
UNNAMED_GROUP_PLACEHOLDER = "Unnamed Group"

# --- Page Configuration & Styling ---
st.set_page_config(
    page_title="WhatsApp Link Scraper",
    page_icon="🚀",
    layout="wide",
    initial_sidebar_state="expanded"
)

st.markdown("""
<style>
    /* Add Custom CSS from the original prompt here for consistent styling */
    body { font-family: 'Inter', 'San Francisco', 'Helvetica Neue', 'Arial', sans-serif; }
    .main-title { font-size: 2.8em; color: #25D366; text-align: center; font-weight: 700; }
    .subtitle { font-size: 1.3em; color: #556; text-align: center; margin-top: 5px; margin-bottom: 30px; }
    .stButton>button { background-color: #25D366; color: #FFFFFF; border-radius: 8px; font-weight: bold; border: none; padding: 10px 18px; transition: all 0.2s ease-in-out; }
    .stButton>button:hover { background-color: #1EBE5A; transform: scale(1.03); }
    .stProgress > div > div > div > div { background-color: #25D366; }
    .metric-card { background-color: #F8F9FA; padding: 20px; border-radius: 10px; text-align: center; border: 1px solid #E9ECEF; }
    .metric-card .metric-value { font-size: 2.2em; font-weight: 700; color: #25D366; }
    .stExpander { border: 1px solid #E9ECEF; border-radius: 8px; }
    .filter-container { background-color: #FDFDFD; padding: 20px; border-radius: 8px; border: 1px dashed #DDE2E5; }
    h4 { color: #259952; border-left: 4px solid #25D366; padding-left: 10px; }
</style>
""", unsafe_allow_html=True)

# --- Utility Functions ---

def get_random_headers():
    """Returns randomized headers to avoid scraping blocks."""
    if ua:
        return {"User-Agent": ua.random, "Accept-Language": "en-US,en;q=0.9"}
    return {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"}

def normalize_whatsapp_link(link):
    """
    Normalizes a WhatsApp link to a standard format, removing '/invite/', query params, and fragments.
    Returns the normalized link or None if it's not a valid WhatsApp chat URL.
    """
    if not isinstance(link, str) or WHATSAPP_DOMAIN not in link:
        return None

    parsed = urlparse(link)
    path = parsed.path
    
    # Remove '/invite/' prefix and ensure a single leading slash
    if path.startswith('/invite/'):
        path = '/' + path[len('/invite/'):]
    else:
        path = '/' + path.lstrip('/')

    # Invite codes are typically alphanumeric and longer than 15 characters
    invite_code = path.lstrip('/')
    if len(invite_code) < 16 or not re.match(r'^[A-Za-z0-9_-]+$', invite_code):
        return None

    return f"{parsed.scheme}://{parsed.netloc}{path}".rstrip('/')

# --- Core Scraping and Validation Logic ---

@st.cache_data(ttl=3600) # Cache validation results for 1 hour
def validate_link(_link):
    """
    Validates a single WhatsApp link by checking its page content for name, logo, and status.
    Uses caching to avoid re-validating the same link within a session.
    """
    result = {"Group Link": _link, "Group Name": UNNAMED_GROUP_PLACEHOLDER, "Logo URL": "", "Status": "Inactive"}
    try:
        response = requests.get(_link, headers=get_random_headers(), timeout=15, allow_redirects=True)
        if response.status_code != 200 or WHATSAPP_DOMAIN not in response.url:
            result["Status"] = "Expired or Invalid"
            return result

        soup = BeautifulSoup(response.text, 'html.parser')
        page_text_lower = soup.get_text().lower()

        # Check for expired/full group messages
        expired_phrases = ["invite link was reset", "group doesn't exist", "link is no longer active", "group is full"]
        if any(phrase in page_text_lower for phrase in expired_phrases):
            result["Status"] = "Full or Expired"
            return result
        
        # Extract Group Name (prioritize OG title)
        og_title = soup.find('meta', property='og:title')
        if og_title and og_title.get('content'):
            result["Group Name"] = html.unescape(og_title['content']).strip()
        else: # Fallback to h2 or other tags
            name_tag = soup.find('h2') or soup.find('strong')
            if name_tag:
                 result["Group Name"] = name_tag.get_text(strip=True)

        # Extract Logo URL (prioritize OG image)
        og_image = soup.find('meta', property='og:image')
        if og_image and og_image.get('content'):
            result["Logo URL"] = html.unescape(og_image['content'])

        # Determine final status based on found data
        if result["Group Name"] != UNNAMED_GROUP_PLACEHOLDER and result["Logo URL"]:
            result["Status"] = "Active"
        elif result["Group Name"] != UNNAMED_GROUP_PLACEHOLDER:
            result["Status"] = "Expired (No Logo)"
        else:
            result["Status"] = "Inactive (No Name)"

    except requests.exceptions.RequestException as e:
        result["Status"] = f"Network Error: {type(e).__name__}"
    except Exception as e:
        result["Status"] = f"Parsing Error: {type(e).__name__}"
    
    return result

def scrape_links_from_url(url, session):
    """Scrapes a single URL for WhatsApp links."""
    found_links = set()
    try:
        response = session.get(url, headers=get_random_headers(), timeout=10)
        response.raise_for_status()
        soup = BeautifulSoup(response.text, 'html.parser')

        for a_tag in soup.find_all('a', href=True):
            normalized = normalize_whatsapp_link(a_tag['href'])
            if normalized:
                found_links.add(normalized)
    except Exception:
        pass # Silently fail for individual URL scrapes
    return found_links

def google_search_and_scrape(query, num_results):
    """Performs a Google search and scrapes results for WhatsApp links."""
    st.info(f"Googling for '{query}' and scraping top {num_results} results...")
    all_found_links = set()
    try:
        search_urls = list(search(query, num_results=num_results, sleep_interval=2, lang="en"))
        if not search_urls:
            st.warning(f"No Google results for '{query}'. Try a different query or check for Google blocks.")
            return set()

        progress_bar = st.progress(0)
        status_text = st.empty()
        
        with requests.Session() as session:
            for i, url in enumerate(search_urls):
                status_text.text(f"Scraping page {i+1}/{len(search_urls)}: {url[:70]}...")
                links_from_page = scrape_links_from_url(url, session)
                all_found_links.update(links_from_page)
                progress_bar.progress((i + 1) / len(search_urls))
        
        status_text.success(f"Scraping complete. Found {len(all_found_links)} potential links for '{query}'.")
        return all_found_links
    except Exception as e:
        st.error(f"An error occurred during Google search: {e}. This might be due to a temporary block from Google.")
        return set()

# --- UI Rendering Functions ---

def render_sidebar_and_input_zone():
    """Renders the sidebar and main input area, returning any newly scraped links."""
    st.sidebar.header("⚙️ Input & Settings")
    input_method = st.sidebar.selectbox("Choose Input Method:", [
        "Search via Google",
        "Scrape a Specific Webpage",
        "Validate Links Manually",
        "Bulk Upload (TXT/CSV links)"
    ])

    newly_scraped_links = set()
    st.subheader(f"🚀 Action Zone: {input_method}")

    if input_method == "Search via Google":
        query = st.text_input("Enter Search Keyword:", placeholder='e.g., "Python developer" whatsapp group')
        num_results = st.slider("Google Results to Scrape:", 1, 50, 10, help="Higher values are slower and risk Google blocks.")
        if st.button("Search & Scrape", use_container_width=True):
            if query:
                newly_scraped_links = google_search_and_scrape(query, num_results)
            else:
                st.warning("Please enter a search keyword.")

    elif input_method == "Scrape a Specific Webpage":
        url = st.text_input("Enter Webpage URL:", placeholder="https://example.com/page-with-links")
        if st.button("Scrape URL", use_container_width=True):
            if url:
                with st.spinner(f"Scraping {url}..."):
                    with requests.Session() as session:
                        newly_scraped_links = scrape_links_from_url(url, session)
                st.success(f"Found {len(newly_scraped_links)} potential links on the page.")
            else:
                st.warning("Please enter a valid URL.")

    elif input_method == "Validate Links Manually":
        links_text = st.text_area("Enter WhatsApp links (one per line):", height=200, placeholder=f"{WHATSAPP_DOMAIN}ABC123XYZ\n{WHATSAPP_DOMAIN}invite/DEF456ABC")
        if st.button("Validate Links", use_container_width=True):
            raw_links = links_text.splitlines()
            for link in raw_links:
                normalized = normalize_whatsapp_link(link)
                if normalized:
                    newly_scraped_links.add(normalized)
            st.info(f"Queued {len(newly_scraped_links)} validly formatted links for validation.")
    
    elif input_method == "Bulk Upload (TXT/CSV links)":
        uploaded_file = st.file_uploader("Upload a .txt or .csv file with one link per line.", type=['txt', 'csv'])
        if uploaded_file:
            raw_links = [line.decode().strip() for line in uploaded_file.readlines()]
            for link in raw_links:
                normalized = normalize_whatsapp_link(link)
                if normalized:
                    newly_scraped_links.add(normalized)
            st.info(f"Read {len(newly_scraped_links)} validly formatted links from '{uploaded_file.name}'.")

    st.sidebar.markdown("---")
    if st.sidebar.button("🗑️ Clear All Results", use_container_width=True):
        st.session_state.results = []
        st.session_state.processed_links = set()
        st.cache_data.clear()
        st.success("All results and cache have been cleared.")
        st.rerun()
        
    return newly_scraped_links

def perform_validation(links_to_validate):
    """Validates a list of links using a thread pool and updates session state."""
    st.info(f"Validating {len(links_to_validate)} new/unprocessed links...")
    progress_bar = st.progress(0)
    status_text = st.empty()
    new_results = []

    with ThreadPoolExecutor(max_workers=MAX_VALIDATION_WORKERS) as executor:
        future_to_link = {executor.submit(validate_link, link): link for link in links_to_validate}
        for i, future in enumerate(as_completed(future_to_link)):
            link = future_to_link[future]
            try:
                result = future.result()
                new_results.append(result)
                st.session_state.processed_links.add(link)
            except Exception as exc:
                new_results.append({"Group Link": link, "Status": f"Validation Error: {exc}"})
            
            progress_bar.progress((i + 1) / len(links_to_validate))
            status_text.text(f"Validated {i+1}/{len(links_to_validate)} links...")
            
    st.session_state.results.extend(new_results)
    status_text.success(f"Validation complete! Added {len(new_results)} new results.")
    time.sleep(2)
    status_text.empty()
    progress_bar.empty()

def render_results_dashboard(results_df):
    """Renders the entire results dashboard including metrics, filters, and tables."""
    st.subheader("📊 Results Dashboard")
    
    # --- Metrics ---
    active_df = results_df[results_df['Status'] == 'Active']
    expired_df = results_df[results_df['Status'].str.contains('Expired|Full|Invalid', case=False, na=False)]
    other_df = results_df[~results_df.index.isin(active_df.index) & ~results_df.index.isin(expired_df.index)]
    
    col1, col2, col3, col4 = st.columns(4)
    col1.markdown(f'<div class="metric-card">Total Links<br><div class="metric-value">{len(results_df)}</div></div>', unsafe_allow_html=True)
    col2.markdown(f'<div class="metric-card">Active Groups<br><div class="metric-value">{len(active_df)}</div></div>', unsafe_allow_html=True)
    col3.markdown(f'<div class="metric-card">Expired/Full<br><div class="metric-value">{len(expired_df)}</div></div>', unsafe_allow_html=True)
    col4.markdown(f'<div class="metric-card">Other/Errors<br><div class="metric-value">{len(other_df)}</div></div>', unsafe_allow_html=True)

    st.markdown("---")
    
    # --- Advanced Filters and Full Data View ---
    with st.expander("🔬 View, Filter & Download Full Dataset", expanded=True):
        with st.form("advanced_filters_form"):
            filter_cols = st.columns([2, 1])
            name_filter = filter_cols[0].text_input("Filter by Group Name keyword:", placeholder="e.g., jobs, python, news")
            status_options = sorted(results_df['Status'].unique())
            status_filter = filter_cols[1].multiselect("Filter by Status:", options=status_options, default=status_options)
            
            submitted = st.form_submit_button("Apply Filters", use_container_width=True)

        # Apply filters
        filtered_df = results_df.copy()
        if name_filter:
            filtered_df = filtered_df[filtered_df['Group Name'].str.contains(name_filter, case=False, na=False)]
        if status_filter:
            filtered_df = filtered_df[filtered_df['Status'].isin(status_filter)]
            
        st.dataframe(filtered_df, use_container_width=True, hide_index=True, column_config={
            "Group Link": st.column_config.LinkColumn("Group Link", display_text="🔗 Join"),
            "Logo URL": st.column_config.ImageColumn("Logo", help="Group Logo"),
        })

        st.download_button(
            label=f"📥 Download Filtered Results ({len(filtered_df)} rows) as CSV",
            data=filtered_df.to_csv(index=False).encode('utf-8'),
            file_name='whatsapp_group_links.csv',
            mime='text/csv',
            use_container_width=True,
            disabled=filtered_df.empty
        )


# --- Main Application Execution ---
def main():
    """Main function to run the Streamlit app."""
    st.markdown('<h1 class="main-title">WhatsApp Link Scraper & Validator</h1>', unsafe_allow_html=True)
    st.markdown('<p class="subtitle">Find, scrape, and validate public WhatsApp group links from Google or any webpage.</p>', unsafe_allow_html=True)

    # Initialize session state
    if 'results' not in st.session_state:
        st.session_state.results = []
    if 'processed_links' not in st.session_state:
        st.session_state.processed_links = set()

    # Render UI and get scraped links
    newly_scraped_links = render_sidebar_and_input_zone()

    # Determine which links need validation
    links_to_validate = list(newly_scraped_links - st.session_state.processed_links)
    
    if links_to_validate:
        perform_validation(links_to_validate)

    # Display results if available
    if st.session_state.results:
        # Create a clean, unique DataFrame for display
        results_df = pd.DataFrame(st.session_state.results).drop_duplicates(subset=['Group Link'], keep='last').reset_index(drop=True)
        render_results_dashboard(results_df)
    elif newly_scraped_links and not links_to_validate:
        st.info("All found links have already been processed in this session.")
    else:
        st.info("👋 Welcome! Choose an input method from the sidebar to get started.")

if __name__ == "__main__":
    main()
