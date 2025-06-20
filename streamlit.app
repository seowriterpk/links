# app.py
import streamlit as st
import pandas as pd
import requests
import html
from bs4 import BeautifulSoup
import re
import time
import io
from urllib.parse import urljoin, urlparse, urlencode, parse_qs
from concurrent.futures import ThreadPoolExecutor, as_completed

# --- Dependency Import & Fallbacks ---

# googlesearch-python
try:
    # Note: The `num_results` parameter is deprecated; the correct parameter is `num`.
    from googlesearch import search as google_search_function_actual
except ImportError:
    st.error("The `googlesearch-python` library is not installed. Please run: `pip install googlesearch-python`")
    def google_search_function_actual(query, num, lang, **kwargs):
        st.error("`googlesearch-python` not found. Cannot perform Google searches.")
        return []

# fake-useragent
try:
    from fake_useragent import UserAgent
    from fake_useragent.errors import FakeUserAgentError
    ua_general = UserAgent()
    def get_random_headers_general():
        try:
            return {"User-Agent": ua_general.random, "Accept-Language": "en-US,en;q=0.9"}
        except (FakeUserAgentError, Exception):
            # Fallback for any error during User-Agent generation
            return {
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36",
                "Accept-Language": "en-US,en;q=0.9"
            }
except ImportError:
    st.warning("`fake-useragent` not found. Install with `pip install fake-useragent`. Using a default User-Agent.", icon="⚠️")
    def get_random_headers_general():
        return {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36",
            "Accept-Language": "en-US,en;q=0.9"
        }

# --- Streamlit Configuration & Constants ---
st.set_page_config(
    page_title="WhatsApp Link Scraper & Validator",
    page_icon="🚀",
    layout="wide",
    initial_sidebar_state="expanded"
)

WHATSAPP_DOMAIN = "chat.whatsapp.com"
WHATSAPP_BASE_URL = "https://chat.whatsapp.com/"
UNNAMED_GROUP_PLACEHOLDER = ""
IMAGE_PATTERN_PPS = re.compile(r'https://pps\.whatsapp\.net/v/t\d+/[-\w\.]+/\d+\.jpg\?.*')
OG_IMAGE_PATTERN = re.compile(r'https?://[^\s/]+/.+\.(jpg|jpeg|png|gif|webp)(\?[^\s]*)?', re.IGNORECASE)
MAX_VALIDATION_WORKERS = 8

# UPGRADE: Regex to capture base URL and invite code, ignoring optional `/invite/`
WHATSAPP_LINK_PATTERN = re.compile(r"(https?://chat\.whatsapp\.com/)(?:invite/)?([A-Za-z0-9_-]{16,})")

# --- Custom CSS ---
st.markdown("""
<style>
/* [Identical CSS from original prompt retained for styling consistency] */
body { font-family: 'Arial', sans-serif; }
.main-title { font-size: 2.8em; color: #25D366; text-align: center; margin-bottom: 0; font-weight: 600; letter-spacing: -1px; }
.subtitle { font-size: 1.3em; color: #555; text-align: center; margin-top: 5px; margin-bottom: 30px; }
.stButton>button { background-color: #25D366; color: #FFFFFF; border-radius: 8px; font-weight: bold; border: none; padding: 10px 18px; margin: 8px 0; transition: background-color 0.3s ease, transform 0.1s ease; }
.stButton>button:hover { background-color: #1EBE5A; transform: scale(1.03); }
.stButton>button:active { transform: scale(0.98); }
.stProgress > div > div > div > div { background-color: #25D366; border-radius: 4px; }
.metric-card { background-color: #F8F9FA; padding: 15px; border-radius: 10px; box-shadow: 0 4px 8px rgba(0,0,0,0.05); color: #333; text-align: center; margin-bottom: 15px; border: 1px solid #E9ECEF; }
.metric-card .metric-value { font-size: 2em; font-weight: 700; margin-top: 5px; margin-bottom: 0; line-height: 1.2; color: #25D366; }
.stTextInput > div > div > input, .stTextArea > div > textarea, .stNumberInput > div > div > input { border: 1px solid #CED4DA !important; border-radius: 6px !important; padding: 10px !important; box-shadow: inset 0 1px 2px rgba(0,0,0,0.075); }
.stTextInput > div > div > input:focus, .stTextArea > div > textarea:focus, .stNumberInput > div > div > input:focus { border-color: #25D366 !important; box-shadow: 0 0 0 0.2rem rgba(37, 211, 102, 0.25) !important; }
.stExpander { border: 1px solid #E9ECEF; border-radius: 8px; padding: 12px; margin-top: 15px; margin-bottom: 15px; box-shadow: 0 2px 4px rgba(0,0,0,0.03); }
.stExpander div[data-testid="stExpanderToggleIcon"] { color: #25D366; font-size: 1.2em; }
.stExpander div[data-testid="stExpanderLabel"] strong { color: #1EBE5A; font-size: 1.1em; }
.filter-container { background-color: #FDFDFD; padding: 15px; border-radius: 8px; margin-bottom: 20px; border: 1px dashed #DDE2E5; }
h4 { color: #259952; margin-top:10px; margin-bottom:10px; border-left: 3px solid #25D366; padding-left: 8px;}
.whatsapp-groups-table { border-collapse: collapse; width: 100%; margin-top: 15px; box-shadow: 0 3px 6px rgba(0,0,0,0.08); border-radius: 8px; overflow: hidden; border: 1px solid #DEE2E6; }
.whatsapp-groups-table caption { caption-side: top; text-align: left; font-weight: 600; padding: 12px 15px; font-size: 1.15em; color: #343A40; background-color: #F8F9FA; border-bottom: 1px solid #DEE2E6;}
.whatsapp-groups-table th { background-color: #343A40; color: white; padding: 14px 12px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; font-size: 0.9em; }
.whatsapp-groups-table td { padding: 12px; vertical-align: middle; text-align: left; font-size: 0.95em; }
.group-logo-img { width: 45px; height: 45px; border-radius: 50%; object-fit: cover; display: block; margin: 0 auto; border: 2px solid #F0F0F0; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
.join-button { display: inline-block; background-color: #25D366; color: #FFFFFF !important; padding: 7px 14px; border-radius: 6px; text-decoration: none; font-weight: 500; text-align: center; white-space: nowrap; font-size: 0.85em; transition: background-color 0.2s ease, transform 0.1s ease; }
.join-button:hover { background-color: #1DB954; color: #FFFFFF !important; text-decoration: none; transform: translateY(-1px); }
</style>
""", unsafe_allow_html=True)

# --- Helper Functions ---

def normalize_whatsapp_link(link):
    """
    UPGRADE: Normalizes WhatsApp links to a standard format (without /invite/) for robust deduplication.
    Accepts:
    - https://chat.whatsapp.com/INVITECODE
    - https://chat.whatsapp.com/invite/INVITECODE
    Returns the normalized link (e.g., https://chat.whatsapp.com/INVITECODE) or None if not a match.
    """
    if not isinstance(link, str):
        return None
    match = WHATSAPP_LINK_PATTERN.match(link.strip())
    if match:
        base_url, invite_code = match.groups()
        return f"{base_url}{invite_code}"
    return None

def load_keywords_from_excel(uploaded_file):
    """Loads keywords from the first column of an Excel file."""
    if uploaded_file is None: return []
    try:
        df = pd.read_excel(io.BytesIO(uploaded_file.getvalue()), engine='openpyxl')
        if df.empty:
            st.warning("Uploaded Excel file is empty.")
            return []
        keywords = [str(kw).strip() for kw in df.iloc[:, 0].dropna() if str(kw).strip()]
        if not keywords:
            st.warning("No valid keywords found in the first column of the Excel file.")
        return keywords
    except Exception as e:
        st.error(f"Error reading Excel file: {e}. Please ensure it's a valid .xlsx file.", icon="❌")
        return []

def load_links_from_file(uploaded_file):
    """Loads links from a TXT or CSV file."""
    if uploaded_file is None: return []
    try:
        content = uploaded_file.getvalue().decode('utf-8')
        if uploaded_file.name.endswith('.csv'):
            df = pd.read_csv(io.StringIO(content))
            if df.empty: return []
            return [link.strip() for link in df.iloc[:, 0].dropna().astype(str) if WHATSAPP_DOMAIN in link]
        else: # Assume TXT file
            return [line.strip() for line in content.splitlines() if WHATSAPP_DOMAIN in line]
    except Exception as e:
        st.error(f"Error processing file '{uploaded_file.name}': {e}", icon="❌")
        return []

# --- Core Scraping & Validation Logic ---

@st.cache_data(ttl=3600, show_spinner=False)
def validate_link(_link):
    """
    Validates a single WhatsApp group link to determine its status, name, and logo.
    Uses @st.cache_data to avoid re-validating the same link within an hour.
    """
    result = {"Group Name": UNNAMED_GROUP_PLACEHOLDER, "Group Link": _link, "Logo URL": "", "Status": "Inactive"}
    try:
        response = requests.get(_link, headers=get_random_headers_general(), timeout=15, allow_redirects=True)
        response.raise_for_status()
        response.encoding = 'utf-8'

        if WHATSAPP_DOMAIN not in response.url:
            result["Status"] = f"Redirected Away ({urlparse(response.url).netloc})"
            return result

        soup = BeautifulSoup(response.text, 'html.parser')

        # Extract Group Name (from og:title or h2/h3 tags)
        og_title = soup.find('meta', property='og:title')
        group_name = html.unescape(og_title['content']).strip() if og_title and og_title.get('content') else ""
        if not group_name:
            h2_tag = soup.find('h2')
            if h2_tag: group_name = h2_tag.get_text(strip=True)

        result["Group Name"] = group_name

        # Extract Logo URL (from og:image)
        og_image = soup.find('meta', property='og:image')
        logo_url = html.unescape(og_image['content']) if og_image and og_image.get('content') else ""
        result["Logo URL"] = logo_url if OG_IMAGE_PATTERN.match(str(logo_url)) else ""

        # Determine Status
        page_text_lower = soup.get_text().lower()
        if any(phrase in page_text_lower for phrase in ["link was reset", "is no longer available", "group is full"]):
            result["Status"] = "Expired or Full"
        elif group_name and "invite" not in group_name.lower(): # A real name was found
            result["Status"] = "Active"
        else: # Default to Inactive if no definite active/expired signals
            result["Status"] = "Inactive"

    except requests.exceptions.Timeout: result["Status"] = "Timeout Error"
    except requests.exceptions.HTTPError as e: result["Status"] = f"HTTP Error {e.response.status_code}"
    except requests.exceptions.RequestException: result["Status"] = "Connection Error"
    except Exception: result["Status"] = "Parsing Error"

    return result

def scrape_whatsapp_links_from_page(url, session):
    """Scrapes a single webpage for normalized WhatsApp links."""
    normalized_links = set()
    try:
        response = session.get(url, headers=get_random_headers_general(), timeout=10)
        response.raise_for_status()

        # Efficiently find all hrefs that contain the WhatsApp domain
        soup = BeautifulSoup(response.text, 'html.parser')
        for a_tag in soup.find_all('a', href=re.compile(WHATSAPP_DOMAIN)):
            href = a_tag.get('href')
            normalized = normalize_whatsapp_link(href)
            if normalized:
                normalized_links.add(normalized)
    except Exception as e:
        st.sidebar.warning(f"Scrape Error on {url[:50]}... ({type(e).__name__})", icon="🕸️")
    return normalized_links

def run_google_search_and_scrape(query, top_n):
    """Performs a Google search and scrapes results for WhatsApp links."""
    st.info(f"Googling '{query}' (top {top_n} results)...")
    all_found_links = set()
    try:
        # UPGRADE: Use `num` instead of deprecated `num_results`
        search_results = list(google_search_function_actual(query, num=top_n, lang="en", sleep_interval=2))
        if not search_results:
            st.warning(f"No Google results for '{query}'. This could be due to the query itself or a temporary Google block.", icon="🤔")
            return set()

        st.success(f"Found {len(search_results)} pages from Google. Scraping them now...")
        prog_bar, stat_txt = st.progress(0), st.empty()

        with requests.Session() as session:
            for i, url in enumerate(search_results):
                stat_txt.text(f"Scraping {i+1}/{len(search_results)}: {url[:70]}...")
                links_from_page = scrape_whatsapp_links_from_page(url, session)
                all_found_links.update(links_from_page)
                prog_bar.progress((i + 1) / len(search_results))

        stat_txt.success(f"Scraping complete. Found {len(all_found_links)} unique WhatsApp links for '{query}'.")
        return all_found_links
    except Exception as e:
        st.error(f"An error occurred during Google search/scraping: {e}", icon="❌")
        return set()

def generate_styled_html_table(df_active):
    """Generates a styled HTML table for active groups."""
    if df_active.empty:
        return "<p style='text-align:center; color:#777; margin-top:20px;'><i>No 'Active' groups match the current display filters.</i></p>"

    rows_html = []
    for _, row in df_active.iterrows():
        logo = row.get("Logo URL", "")
        name = html.escape(row.get("Group Name", "Unknown Group"))
        link = row.get("Group Link", "")
        logo_html = f'<img src="{logo}" alt="{name} Logo" class="group-logo-img" loading="lazy">' if logo else '<div class="group-logo-img" style="background-color:#e0e0e0;"></div>'
        join_button = f'<a href="{link}" class="join-button" target="_blank" rel="noopener noreferrer">Join Group</a>' if link else 'N/A'
        rows_html.append(f'<tr><td>{logo_html}</td><td>{name}</td><td style="text-align:right;">{join_button}</td></tr>')

    return f"""
    <table class="whatsapp-groups-table">
        <caption>Filtered Active WhatsApp Groups</caption>
        <thead><tr><th>Logo</th><th>Group Name</th><th style="text-align:right;">Action</th></tr></thead>
        <tbody>{''.join(rows_html)}</tbody>
    </table>
    """

# --- Main Application Logic ---
def main():
    st.markdown('<h1 class="main-title">WhatsApp Link Scraper & Validator 🚀</h1>', unsafe_allow_html=True)
    st.markdown('<p class="subtitle">Discover, Scrape, Validate, and Manage WhatsApp Group Links with Enhanced Filtering.</p>', unsafe_allow_html=True)

    # Initialize session state
    if 'results' not in st.session_state: st.session_state.results = []
    if 'styled_table_name_keywords' not in st.session_state: st.session_state.styled_table_name_keywords = ""
    if 'styled_table_current_limit' not in st.session_state: st.session_state.styled_table_current_limit = 50
    if 'adv_filter_status' not in st.session_state: st.session_state.adv_filter_status = ["Active"]
    if 'adv_filter_name_keywords' not in st.session_state: st.session_state.adv_filter_name_keywords = ""

    # --- Sidebar for Inputs & Settings ---
    with st.sidebar:
        st.header("⚙️ Input & Settings")
        input_method = st.selectbox("Choose Input Method:", [
            "Search and Scrape from Google",
            "Scrape from Specific Webpage URL",
            "Enter Links Manually (for Validation)",
            "Upload File (Keywords or Links)"
        ])

        # --- Action Buttons & Inputs ---
        links_to_process = set()
        st.subheader("🚀 Action Zone")

        if input_method == "Search and Scrape from Google":
            query = st.text_input("Enter Google Search Query:", placeholder="e.g., Python developer WhatsApp group")
            top_n = st.slider("Google Results to Scrape:", 1, 50, 10, help="Number of Google search results to process. Higher values are slower.")
            if st.button("🔍 Search & Scrape", use_container_width=True):
                if query:
                    links_to_process.update(run_google_search_and_scrape(query, top_n))
                else:
                    st.warning("Please enter a search query.")

        elif input_method == "Scrape from Specific Webpage URL":
            url = st.text_input("Enter Webpage URL:", placeholder="https://example.com/page-with-links")
            if st.button("🕸️ Scrape URL", use_container_width=True):
                if url:
                    with st.spinner(f"Scraping {url}..."), requests.Session() as session:
                        found = scrape_whatsapp_links_from_page(url, session)
                        st.success(f"Found {len(found)} WhatsApp links on the page.")
                        links_to_process.update(found)
                else:
                    st.warning("Please enter a valid URL.")

        elif input_method == "Enter Links Manually (for Validation)":
            links_text = st.text_area("Enter WhatsApp Links (one per line):", height=150, placeholder=f"{WHATSAPP_BASE_URL}xxxxxxxx\n{WHATSAPP_BASE_URL}yyyyyyyy")
            if st.button("✅ Validate Manual Links", use_container_width=True):
                raw_links = [line.strip() for line in links_text.split('\n') if line.strip()]
                manual_links = {normalized for link in raw_links if (normalized := normalize_whatsapp_link(link))}
                st.info(f"Found {len(manual_links)} validly formatted links to process.")
                links_to_process.update(manual_links)

        elif input_method == "Upload File (Keywords or Links)":
            uploaded_file = st.file_uploader("Upload .xlsx (keywords) or .txt/.csv (links)", type=["xlsx", "txt", "csv"])
            if st.button("📂 Process File", use_container_width=True) and uploaded_file:
                if uploaded_file.name.endswith('.xlsx'):
                    keywords = load_keywords_from_excel(uploaded_file)
                    for i, keyword in enumerate(keywords):
                        st.write(f"--- \n**Processing keyword {i+1}/{len(keywords)}: '{keyword}'**")
                        links_to_process.update(run_google_search_and_scrape(keyword, 10)) # Default to 10 results for bulk
                else:
                    raw_links = load_links_from_file(uploaded_file)
                    file_links = {normalized for link in raw_links if (normalized := normalize_whatsapp_link(link))}
                    st.info(f"Found {len(file_links)} validly formatted links in the file.")
                    links_to_process.update(file_links)

        st.markdown("---")
        if st.button("🗑️ Clear All Results", use_container_width=True):
            st.session_state.results = []
            st.cache_data.clear()
            st.rerun()

    # --- Validation and Result Processing ---
    existing_links = {res['Group Link'] for res in st.session_state.results}
    new_links_to_validate = list(links_to_process - existing_links)

    if new_links_to_validate:
        st.info(f"Validating {len(new_links_to_validate)} new WhatsApp links...")
        prog_val, stat_val = st.progress(0), st.empty()
        new_results = []
        with ThreadPoolExecutor(max_workers=MAX_VALIDATION_WORKERS) as executor:
            futures = {executor.submit(validate_link, link): link for link in new_links_to_validate}
            for i, future in enumerate(as_completed(futures)):
                new_results.append(future.result())
                prog_val.progress((i + 1) / len(new_links_to_validate))
                stat_val.text(f"Validated {i+1}/{len(new_links_to_validate)} links...")
        
        # Prepend new results to show them at the top
        st.session_state.results = new_results + st.session_state.results
        stat_val.success(f"Validation complete for {len(new_links_to_validate)} links!")
        # Use st.rerun() to clear the action state and prevent re-processing on widget interactions
        st.rerun()

    # --- Display Results ---
    if st.session_state.results:
        df_master = pd.DataFrame(st.session_state.results).drop_duplicates(subset=['Group Link']).reset_index(drop=True)

        # --- Summary Metrics ---
        st.subheader("📊 Results Summary")
        active_df = df_master[df_master['Status'] == 'Active']
        expired_df = df_master[df_master['Status'] == 'Expired or Full']
        inactive_df = df_master[df_master['Status'] == 'Inactive']
        error_df = df_master[~df_master['Status'].isin(['Active', 'Expired or Full', 'Inactive'])]

        c1, c2, c3, c4 = st.columns(4)
        c1.markdown(f'<div class="metric-card">Total<br><div class="metric-value">{len(df_master)}</div></div>', unsafe_allow_html=True)
        c2.markdown(f'<div class="metric-card" style="color:#25D366;">Active<br><div class="metric-value">{len(active_df)}</div></div>', unsafe_allow_html=True)
        c3.markdown(f'<div class="metric-card" style="color:#FFC107;">Expired/Full<br><div class="metric-value">{len(expired_df)}</div></div>', unsafe_allow_html=True)
        c4.markdown(f'<div class="metric-card" style="color:#6C757D;">Other<br><div class="metric-value">{len(inactive_df) + len(error_df)}</div></div>', unsafe_allow_html=True)

        # --- Active Groups Styled Table ---
        with st.expander("✨ View and Filter Active Groups", expanded=True):
            if not active_df.empty:
                # FIX: `StreamlitValueAboveMaxError`
                # 1. Calculate the max value based on the filtered dataframe length.
                max_limit_val = max(1, len(active_df))
                # 2. Clamp the session state value to ensure it's not greater than the max value.
                clamped_limit = min(st.session_state.styled_table_current_limit, max_limit_val)

                with st.form("styled_table_filters_form"):
                    name_kw = st.text_input("Filter by Group Name:", st.session_state.styled_table_name_keywords)
                    limit = st.number_input("Max Groups to Display:", 1, max_limit_val, clamped_limit)
                    if st.form_submit_button("Apply Filters"):
                        st.session_state.styled_table_name_keywords = name_kw
                        st.session_state.styled_table_current_limit = limit
                        st.rerun()

                filtered_active_df = active_df
                if st.session_state.styled_table_name_keywords:
                    search_regex = '|'.join([re.escape(kw.strip()) for kw in st.session_state.styled_table_name_keywords.split(',')])
                    filtered_active_df = active_df[active_df['Group Name'].str.contains(search_regex, case=False, na=False)]

                st.markdown(generate_styled_html_table(filtered_active_df.head(st.session_state.styled_table_current_limit)), unsafe_allow_html=True)
            else:
                st.info("No 'Active' groups found yet. Try another search or validation.")

        # --- Advanced Filtering & Downloads Expander ---
        with st.expander("🔬 Advanced Filtering & Full Dataset View"):
            # UPGRADE: Use st.form for a better UX, preventing reruns on every widget interaction.
            with st.form("advanced_filters_form"):
                st.markdown("#### Filter Full Dataset (for Download/Analysis)")
                all_statuses = sorted(list(df_master['Status'].unique()))
                
                adv_status_sel = st.multiselect("Filter by Status:", options=all_statuses, default=st.session_state.adv_filter_status)
                adv_name_kw_sel = st.text_input("Filter by Group Name:", value=st.session_state.adv_filter_name_keywords)

                submitted = st.form_submit_button("Apply Advanced Filters & Update Preview")
                if submitted:
                    st.session_state.adv_filter_status = adv_status_sel
                    st.session_state.adv_filter_name_keywords = adv_name_kw_sel
                    st.rerun()

            # Apply filters from session state
            df_for_view = df_master.copy()
            filters_applied = False
            if st.session_state.adv_filter_status:
                df_for_view = df_for_view[df_for_view['Status'].isin(st.session_state.adv_filter_status)]
                filters_applied = True
            if st.session_state.adv_filter_name_keywords:
                search_regex = '|'.join([re.escape(kw.strip()) for kw in st.session_state.adv_filter_name_keywords.split(',')])
                df_for_view = df_for_view[df_for_view['Group Name'].str.contains(search_regex, case=False, na=False)]
                filters_applied = True
            
            preview_label = "Filtered" if filters_applied else "All"
            st.markdown(f"**Preview of Data for Download ({preview_label} - {len(df_for_view)} rows):**")
            st.dataframe(df_for_view, use_container_width=True, hide_index=True)

            # --- Download Buttons ---
            st.subheader("📥 Download Results (CSV)")
            csv_data = df_for_view.to_csv(index=False, encoding='utf-8-sig').encode('utf-8-sig')
            
            # FIX: The original code had complex logic here. This is simpler and more robust.
            # `df_for_adv_dl_view.empty` is now `df_for_view.empty`
            if not df_for_view.empty:
                st.download_button(
                    label=f"📥 Download {preview_label} Results ({len(df_for_view)} rows)",
                    data=csv_data,
                    file_name=f"{preview_label.lower()}_whatsapp_groups.csv",
                    mime="text/csv",
                    use_container_width=True
                )
            else:
                st.button("📥 Download Results", disabled=True, use_container_width=True, help="No data matching current filters.")

    else:
        st.info("Start by searching, scraping, or uploading links to see results here.", icon="ℹ️")

if __name__ == "__main__":
    main()
