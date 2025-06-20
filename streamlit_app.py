import streamlit as st
import pandas as pd
import requests
from bs4 import BeautifulSoup
import re
import time
from urllib.parse import urlparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from fake_useragent import UserAgent
from googlesearch import search as google_search

# Streamlit configuration
st.set_page_config(page_title="WhatsApp Group Link Scraper", layout="wide")

# Constants
WHATSAPP_DOMAIN = "https://chat.whatsapp.com/"
MAX_WORKERS = 8

# Initialize fake-useragent
ua = UserAgent()

# Custom CSS for styling
st.markdown("""
<style>
    .main-title { font-size: 2.5em; color: #25D366; text-align: center; }
    .stButton>button { background-color: #25D366; color: white; border-radius: 5px; }
    .stButton>button:hover { background-color: #1EBE5A; }
    .whatsapp-table { width: 100%; border-collapse: collapse; margin-top: 20px; }
    .whatsapp-table th { background-color: #25D366; color: white; padding: 10px; }
    .whatsapp-table td { padding: 10px; border-bottom: 1px solid #ddd; }
    .whatsapp-table tr:nth-child(even) { background-color: #f9f9f9; }
    .whatsapp-table tr:hover { background-color: #f1f1f1; }
</style>
""", unsafe_allow_html=True)

# Helper Functions
def get_random_headers():
    return {"User-Agent": ua.random, "Accept-Language": "en-US,en;q=0.9"}

def scrape_whatsapp_links(url):
    """Scrape WhatsApp group links from a given URL."""
    links = set()
    try:
        response = requests.get(url, headers=get_random_headers(), timeout=10)
        response.raise_for_status()
        soup = BeautifulSoup(response.text, 'html.parser')
        
        # Extract from <a> tags
        for a in soup.find_all('a', href=True):
            href = a['href']
            if href.startswith(WHATSAPP_DOMAIN):
                parsed = urlparse(href)
                clean_link = f"{parsed.scheme}://{parsed.netloc}{parsed.path}"
                links.add(clean_link)
        
        # Extract from text
        text = soup.get_text()
        pattern = re.compile(r'https://chat\.whatsapp\.com/(?:invite/)?[A-Za-z0-9]{22}')
        links.update(pattern.findall(text))
        
    except Exception as e:
        st.warning(f"Failed to scrape {url}: {str(e)}")
    return list(links)

def validate_link(link):
    """Validate a WhatsApp link and extract group name if possible."""
    result = {"Group Link": link, "Group Name": "", "Status": "Unknown"}
    try:
        response = requests.get(link, headers=get_random_headers(), timeout=10)
        if response.status_code == 200:
            soup = BeautifulSoup(response.text, 'html.parser')
            title = soup.find('meta', property='og:title')
            group_name = title['content'].strip() if title and title.get('content') else ""
            result["Group Name"] = group_name if group_name else "Unnamed Group"
            result["Status"] = "Active" if group_name else "Inactive"
        else:
            result["Status"] = f"Error {response.status_code}"
    except Exception as e:
        result["Status"] = f"Failed: {str(e)}"
    return result

# Main Application
def main():
    st.markdown('<h1 class="main-title">WhatsApp Group Link Scraper</h1>', unsafe_allow_html=True)
    
    # Session state initialization
    if 'results' not in st.session_state:
        st.session_state.results = []
    
    # Keyword input
    keyword = st.text_input("Enter a keyword (e.g., 'Python programming WhatsApp group')", "")
    
    if st.button("Scrape WhatsApp Links"):
        if not keyword:
            st.error("Please enter a keyword.")
        else:
            with st.spinner("Searching Google and scraping links..."):
                # Google search for top 20 results
                search_query = f"{keyword} site:chat.whatsapp.com"
                urls = list(google_search(search_query, num_results=20, lang="en"))
                
                if not urls:
                    st.warning("No Google search results found.")
                    return
                
                # Scrape links from each URL
                all_links = set()
                progress_bar = st.progress(0)
                for i, url in enumerate(urls):
                    links = scrape_whatsapp_links(url)
                    all_links.update(links)
                    progress_bar.progress((i + 1) / len(urls))
                
                if not all_links:
                    st.warning("No WhatsApp links found in the search results.")
                    return
                
                # Validate links
                st.info(f"Found {len(all_links)} unique links. Validating...")
                results = []
                with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
                    futures = [executor.submit(validate_link, link) for link in all_links]
                    for i, future in enumerate(as_completed(futures)):
                        results.append(future.result())
                        progress_bar.progress((i + 1) / len(all_links))
                
                st.session_state.results = results
                st.success(f"Scraping and validation complete! Found {len(results)} links.")
    
    # Display results
    if st.session_state.results:
        df = pd.DataFrame(st.session_state.results)
        active_df = df[df['Status'] == 'Active']
        
        if not active_df.empty:
            st.subheader("Active WhatsApp Groups")
            html = '<table class="whatsapp-table"><tr><th>Group Name</th><th>Group Link</th></tr>'
            for _, row in active_df.iterrows():
                html += f'<tr><td>{row["Group Name"]}</td><td><a href="{row["Group Link"]}" target="_blank">{row["Group Link"]}</a></td></tr>'
            html += '</table>'
            st.markdown(html, unsafe_allow_html=True)
            
            # CSV Download
            csv = df.to_csv(index=False)
            st.download_button(
                label="Download Results as CSV",
                data=csv,
                file_name="whatsapp_groups.csv",
                mime="text/csv"
            )
        else:
            st.info("No active WhatsApp groups found.")
    
    else:
        st.info("Enter a keyword and click 'Scrape WhatsApp Links' to begin.")

if __name__ == "__main__":
    main()
